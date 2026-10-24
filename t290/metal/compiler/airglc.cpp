/* airglc: AIR bitcode -> specialized LLVM IR -> GLSL ES 3.10 (see airglc.h).
 * Mirrors t290/metal/airgl/airgl.py and specialize.py; keep them in step. */
#include "airglc.h"

#include <llvm/ADT/StringExtras.h>
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/DataLayout.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/IntrinsicInst.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Metadata.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Operator.h>
#include <llvm/Passes/PassBuilder.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

using namespace llvm;

namespace {

struct Unsupported {
	std::string what;
};

[[noreturn]] void fail(const std::string &s) { throw Unsupported{s}; }

std::string fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));
std::string fmt(const char *f, ...)
{
	char buf[4096];
	va_list ap;
	va_start(ap, f);
	int n = vsnprintf(buf, sizeof(buf), f, ap);
	va_end(ap);
	if (n < (int)sizeof(buf)) return std::string(buf, n > 0 ? n : 0);
	std::string out(n, '\0');
	va_start(ap, f);
	vsnprintf(&out[0], n + 1, f, ap);
	va_end(ap);
	return out;
}

std::string join(const std::vector<std::string> &v, const char *sep = ", ")
{
	std::string o;
	for (size_t i = 0; i < v.size(); i++) {
		if (i) o += sep;
		o += v[i];
	}
	return o;
}

std::string sanitize(StringRef s)
{
	std::string o;
	for (char c : s) {
		char d = isalnum((unsigned char)c) ? c : '_';
		if (d == '_' && !o.empty() && o.back() == '_') continue;     /* "__" is reserved in GLSL */
		o += d;
	}
	return o;
}

std::string fnum(double x)
{
	if (std::isnan(x)) return "(0.0/0.0)";
	if (std::isinf(x)) return x < 0 ? "(-1.0/0.0)" : "(1.0/0.0)";
	char buf[64];
	snprintf(buf, sizeof(buf), "%.9g", x);
	std::string s = buf;
	size_t e = s.find_first_of("eE");
	std::string m = e == std::string::npos ? s : s.substr(0, e);
	if (m.find('.') == std::string::npos) m += ".0";
	return e == std::string::npos ? m : m + "e" + s.substr(e + 1);
}

std::string ilit(int64_t x, unsigned bits)
{
	if (bits == 1) return (x & 1) ? "true" : "false";
	uint64_t mask = bits >= 32 ? 0xffffffffull : ((1ull << bits) - 1);
	uint64_t u = (uint64_t)x & mask;
	int64_t v = (int64_t)(int32_t)(uint32_t)u;
	if (bits < 32) v = (int64_t)u;
	if (v == INT32_MIN) return "int(0x80000000u)";       /* not a valid GLSL literal */
	return v >= 0 ? std::to_string(v) : "(" + std::to_string(v) + ")";
}

/* ---------------------------------------------------------------- metadata items */

struct MI {
	enum K { Int, Str, List, Ref } k = Str;
	int64_t i = 0;
	std::string s;
	std::vector<MI> l;
	bool is(const char *t) const { return k == Str && s == t; }
};

MI flatten(const Metadata *md)
{
	MI out;
	if (auto *s = dyn_cast<MDString>(md)) {
		out.k = MI::Str; out.s = s->getString().str();
	} else if (auto *c = dyn_cast<ConstantAsMetadata>(md)) {
		if (auto *ci = dyn_cast<ConstantInt>(c->getValue())) {
			out.k = MI::Int; out.i = ci->getSExtValue();
		} else {
			out.k = MI::Ref; out.s = "@" + c->getValue()->getName().str();
		}
	} else if (auto *v = dyn_cast<ValueAsMetadata>(md)) {
		out.k = MI::Ref; out.s = "@" + v->getValue()->getName().str();
	} else if (auto *n = dyn_cast<MDNode>(md)) {
		out.k = MI::List;
		for (const MDOperand &op : n->operands())
			if (op) out.l.push_back(flatten(op.get()));
	}
	return out;
}

int find(const std::vector<MI> &v, const char *key)
{
	for (size_t i = 0; i < v.size(); i++)
		if (v[i].is(key)) return (int)i;
	return -1;
}
bool has(const std::vector<MI> &v, const char *key) { return find(v, key) >= 0; }
int64_t attr_int(const std::vector<MI> &v, const char *key, int64_t def = -1)
{
	int i = find(v, key);
	return (i >= 0 && i + 1 < (int)v.size() && v[i + 1].k == MI::Int) ? v[i + 1].i : def;
}
std::string attr_str(const std::vector<MI> &v, const char *key)
{
	int i = find(v, key);
	return (i >= 0 && i + 1 < (int)v.size() && v[i + 1].k == MI::Str) ? v[i + 1].s : std::string();
}

/* strip "air.function_constant", {pred} -> (rest, pred global name) */
std::vector<MI> strip_pred(const std::vector<MI> &items, std::string *pred)
{
	std::vector<MI> rest;
	for (size_t i = 0; i < items.size(); i++) {
		if (items[i].is("air.function_constant") && i + 1 < items.size()) {
			const MI &p = items[i + 1];
			if (pred && p.k == MI::List && !p.l.empty()) *pred = p.l[0].s;
			i++;
			continue;
		}
		rest.push_back(items[i]);
	}
	return rest;
}

std::string varying_key(const std::string &gen)
{
	std::string s = gen;
	if (s.rfind("generated(", 0) == 0) s = s.substr(10);
	if (!s.empty() && s.back() == ')') s.pop_back();
	std::string o;
	for (char c : s) o += isalnum((unsigned char)c) ? c : '_';
	return o;
}

/* ---------------------------------------------------------------- JSON */

struct J {
	std::string s;
	static std::string q(const std::string &x)
	{
		std::string o = "\"";
		for (char c : x) {
			if (c == '"' || c == '\\') o += '\\';
			o += c;
		}
		return o + "\"";
	}
};

/* ---------------------------------------------------------------- values */

struct Mem {
	std::string kind, name;       /* ubo tbuf ssbo array texture sampler fc null */
	int index = -1, constSampler = -1;
	std::string dim = "2d", code;
	int64_t words = 0;
	bool writable = false;
};
using MemP = std::shared_ptr<Mem>;

struct Off {
	bool c = true;
	int64_t v = 0;
	std::string e;
	std::string str() const { return c ? std::to_string(v) : e; }
};

struct GV {
	enum K { None, Expr, Ptr, Choice } k = None;
	std::string e;                /* Expr */
	MemP mem;                     /* Ptr */
	Off off;
	Type *elem = nullptr;
	std::string sel;              /* Choice */
	std::shared_ptr<std::vector<GV>> opts;

	static GV expr(std::string s) { GV g; g.k = Expr; g.e = std::move(s); return g; }
	static GV ptr(MemP m, Off o, Type *t) { GV g; g.k = Ptr; g.mem = std::move(m); g.off = std::move(o); g.elem = t; return g; }
	static GV choice(std::string s, std::vector<GV> o)
	{
		GV g; g.k = Choice; g.sel = std::move(s); g.opts = std::make_shared<std::vector<GV>>(std::move(o)); return g;
	}
	bool isPtr() const { return k == Ptr || k == Choice; }
	GV add(const Off &o) const
	{
		GV g = *this;
		if (off.c && o.c) { g.off.v = off.v + o.v; return g; }
		if (o.c && o.v == 0) return g;
		g.off.c = false;
		g.off.e = "(" + off.str() + " + " + o.str() + ")";
		return g;
	}
	std::string pick(const std::vector<std::string> &ex) const
	{
		std::string out = ex.back();
		for (int k = (int)ex.size() - 2; k >= 0; k--)
			out = fmt("((%s) == %d ? %s : %s)", sel.c_str(), k, ex[k].c_str(), out.c_str());
		return out;
	}
};

/* ---------------------------------------------------------------- translator */

class Translator {
public:
	Translator(Module &m, Function &f, std::string stage)
	    : M(m), F(f), DL(m.getDataLayout()), stage(std::move(stage)) {}

	std::string glsl, json;
	void run();

private:
	Module &M;
	Function &F;
	const DataLayout &DL;
	std::string stage;

	std::map<const Value *, GV> vals;
	std::map<const Value *, std::string> names;
	std::vector<std::string> decls, body, gout, initlines;
	std::set<std::string> declared;
	std::map<std::string, MemP> mems;
	std::map<Type *, std::string> structs;
	std::vector<std::pair<std::string, Type *>> structOrder;
	std::map<std::string, std::pair<int64_t, bool>> uboSize;
	std::map<std::string, std::string> pairs;
	std::set<std::pair<int, std::string>> usesFc;
	std::vector<MI> outMeta;
	std::map<const BasicBlock *, std::vector<PHINode *>> phis;
	std::string prefix;
	int tmp = 0, depth = 1, nameSeq = 0;
	bool needTbuf = false, needRtHeight = false;
	/* reflection */
	std::vector<std::string> rInputs, rOutputs, rBuffers, rTextures, rSamplers, rPairs, rConstSamplers, rImages;
	std::vector<int64_t> fbInputs;

	std::string newt(const char *p) { return fmt("%s%d", p, ++tmp); }
	void emit(const std::string &s) { body.push_back(std::string(depth * 4, ' ') + s); }

	/* ---- types */
	std::string gty(Type *t)
	{
		if (t->isFloatingPointTy()) return "float";
		if (auto *it = dyn_cast<IntegerType>(t)) return it->getBitWidth() == 1 ? "bool" : "int";
		if (auto *vt = dyn_cast<FixedVectorType>(t)) {
			unsigned n = vt->getNumElements();
			if (n > 4) fail(fmt("vector width %u", n));
			Type *e = vt->getElementType();
			if (e->isFloatingPointTy()) return fmt("vec%u", n);
			if (e->isIntegerTy(1)) return fmt("bvec%u", n);
			if (e->isIntegerTy()) return fmt("ivec%u", n);
		}
		if (t->isStructTy() || t->isArrayTy()) return sname(t);
		std::string s;
		raw_string_ostream os(s);
		t->print(os);
		fail("type " + os.str());
	}
	std::string sname(Type *t)
	{
		auto it = structs.find(t);
		if (it != structs.end()) return it->second;
		std::string n = fmt("S%zu", structs.size());
		structs[t] = n;
		/* members first (declaration order) */
		if (auto *st = dyn_cast<StructType>(t)) for (Type *e : st->elements()) if (e->isStructTy() || e->isArrayTy()) gty(e);
		if (auto *at = dyn_cast<ArrayType>(t)) if (at->getElementType()->isStructTy() || at->getElementType()->isArrayTy()) gty(at->getElementType());
		structOrder.push_back({n, t});
		return n;
	}
	std::string sdecl(const std::string &n, Type *t)
	{
		if (auto *at = dyn_cast<ArrayType>(t)) return fmt("struct %s { %s e[%llu]; };", n.c_str(), gty(at->getElementType()).c_str(), (unsigned long long)at->getNumElements());
		auto *st = cast<StructType>(t);
		std::string o = "struct " + n + " {";
		for (unsigned i = 0; i < st->getNumElements(); i++) o += fmt(" %s f%u;", gty(st->getElementType(i)).c_str(), i);
		return o + " };";
	}
	std::string zero(Type *t)
	{
		if (t->isFloatingPointTy()) return "0.0";
		if (t->isIntegerTy()) return t->isIntegerTy(1) ? "false" : "0";
		if (auto *vt = dyn_cast<FixedVectorType>(t)) return gty(t) + "(" + zero(vt->getElementType()) + ")";
		if (auto *st = dyn_cast<StructType>(t)) {
			std::vector<std::string> v;
			for (Type *e : st->elements()) v.push_back(zero(e));
			return gty(t) + "(" + join(v) + ")";
		}
		if (auto *at = dyn_cast<ArrayType>(t)) {
			std::vector<std::string> v(at->getNumElements(), zero(at->getElementType()));
			return fmt("%s(%s[%zu](%s))", gty(t).c_str(), gty(at->getElementType()).c_str(), v.size(), join(v).c_str());
		}
		fail("zero of type");
	}
	static unsigned bitsOf(Type *t) { return t->getScalarSizeInBits(); }
	Type *scal(Type *t) { return t->getScalarType(); }
	bool isVec(Type *t) { return isa<FixedVectorType>(t); }
	unsigned vn(Type *t) { return cast<FixedVectorType>(t)->getNumElements(); }
	int64_t asize(Type *t) { return (int64_t)DL.getTypeAllocSize(t); }
	int64_t foff(StructType *st, unsigned i) { return (int64_t)DL.getStructLayout(st)->getElementOffset(i); }
	int64_t estride(Type *t)    /* element step inside an aggregate */
	{
		if (auto *at = dyn_cast<ArrayType>(t)) return asize(at->getElementType());
		return bitsOf(cast<FixedVectorType>(t)->getElementType()) / 8;
	}

	/* ---- values */
	GV val(Value *v, Type *t = nullptr)
	{
		if (!t) t = v->getType();
		auto it = vals.find(v);
		if (it != vals.end()) return it->second;
		if (isa<Instruction>(v) || isa<Argument>(v)) fail("use before def " + v->getName().str());
		if (auto *ci = dyn_cast<ConstantInt>(v)) return GV::expr(ilit(ci->getSExtValue(), ci->getBitWidth()));
		if (auto *cf = dyn_cast<ConstantFP>(v)) {
			APFloat f = cf->getValueAPF();
			bool lost;
			f.convert(APFloat::IEEEdouble(), APFloat::rmNearestTiesToEven, &lost);
			return GV::expr(fnum(f.convertToDouble()));
		}
		if (isa<ConstantPointerNull>(v)) {
			auto m = std::make_shared<Mem>(); m->kind = "null"; m->name = "null";
			return GV::ptr(m, Off{}, t->getPointerElementType());
		}
		if (isa<UndefValue>(v) || isa<ConstantAggregateZero>(v)) {
			if (t->isPointerTy()) { auto m = std::make_shared<Mem>(); m->kind = "null"; m->name = "null"; return GV::ptr(m, Off{}, t->getPointerElementType()); }
			return GV::expr(zero(t));
		}
		if (auto *gvar = dyn_cast<GlobalVariable>(v)) return globalPtr(gvar);
		if (auto *ce = dyn_cast<ConstantExpr>(v)) {
			if (auto *gep = dyn_cast<GEPOperator>(ce)) {
				std::vector<Value *> idx(gep->idx_begin(), gep->idx_end());
				return doGep(val(gep->getPointerOperand()), gep->getSourceElementType(), idx);
			}
			if (ce->getOpcode() == Instruction::BitCast || ce->getOpcode() == Instruction::AddrSpaceCast) {
				GV x = val(ce->getOperand(0));
				return recast(x, ce->getType());
			}
			fail(std::string("constant expression ") + ce->getOpcodeName());
		}
		if (auto *c = dyn_cast<Constant>(v)) {
			if (isVec(t) || t->isStructTy() || t->isArrayTy()) {
				std::vector<std::string> el;
				unsigned n = isVec(t) ? vn(t) : t->isStructTy() ? t->getStructNumElements() : (unsigned)t->getArrayNumElements();
				for (unsigned i = 0; i < n; i++) {
					Constant *e = c->getAggregateElement(i);
					Type *et = isVec(t) ? scal(t) : t->isStructTy() ? t->getStructElementType(i) : t->getArrayElementType();
					el.push_back(val(e, et).e);
				}
				if (t->isArrayTy())
					return GV::expr(fmt("%s(%s[%u](%s))", gty(t).c_str(), gty(t->getArrayElementType()).c_str(), n, join(el).c_str()));
				return GV::expr(gty(t) + "(" + join(el) + ")");
			}
		}
		fail("value kind");
	}
	std::string ex(Value *v, Type *t = nullptr)
	{
		GV g = val(v, t);
		if (g.k != GV::Expr) fail("pointer used as value");
		return g.e;
	}
	GV recast(const GV &x, Type *to)
	{
		Type *el = to->isPointerTy() ? to->getPointerElementType() : x.elem;
		if (x.k == GV::Choice) {
			std::vector<GV> o;
			for (auto &e : *x.opts) o.push_back(recast(e, to));
			return GV::choice(x.sel, o);
		}
		if (x.k != GV::Ptr) fail("cast of value to pointer");
		GV g = x; g.elem = el; return g;
	}

	static bool fcIndex(StringRef name, int *idx, std::string *code)
	{
		size_t p = name.find("MTL_FC_INIT_");
		if (p == StringRef::npos) return false;
		StringRef rest = name.substr(p + 12);
		size_t u = rest.find('_');
		if (u == StringRef::npos) return false;
		*idx = std::atoi(rest.substr(0, u).str().c_str());
		*code = rest.substr(u + 1).str();
		return true;
	}

	GV globalPtr(GlobalVariable *g)
	{
		std::string name = "@" + g->getName().str();
		Type *vt = g->getValueType();
		if (g->getSection() == "air.fc_initializer") {
			auto m = std::make_shared<Mem>(); m->kind = "fc"; m->name = name;
			if (!fcIndex(g->getName(), &m->index, &m->code)) fail("function constant name");
			return GV::ptr(m, Off{}, vt);
		}
		auto it = mems.find(name);
		if (it != mems.end()) return GV::ptr(it->second, Off{}, vt);
		if (g->getName().startswith("__air_sampler_state")) {
			auto m = std::make_shared<Mem>(); m->kind = "sampler";
			m->constSampler = (int)rConstSamplers.size();
			m->name = fmt("cs%d", m->constSampler);
			uint64_t st = 0;
			if (g->hasInitializer()) if (auto *ci = dyn_cast<ConstantInt>(g->getInitializer())) st = ci->getZExtValue();
			rConstSamplers.push_back(fmt("{\"id\": %d, \"state\": %llu}", m->constSampler, (unsigned long long)st));
			mems[name] = m;
			return GV::ptr(m, Off{}, vt);
		}
		int64_t words = std::max<int64_t>(1, (asize(vt) + 3) / 4);
		std::string mname = "G" + sanitize(g->getName());
		if (mname.size() > 41) mname = "G" + mname.substr(mname.size() - 40);
		std::vector<uint32_t> init;
		bool hasInit = g->hasInitializer() && !isa<UndefValue>(g->getInitializer());
		if (hasInit) init = constWords(g->getInitializer(), vt);
		auto m = std::make_shared<Mem>(); m->kind = "array"; m->name = mname; m->words = words;
		m->writable = !g->isConstant();
		if (g->isConstant() && hasInit) {
			std::vector<std::string> w;
			for (uint32_t x : init) w.push_back(fmt("%uu", x));
			gout.push_back(fmt("const uint %s[%lld] = uint[%lld](%s);", mname.c_str(), (long long)words, (long long)words, join(w).c_str()));
		} else {
			gout.push_back(fmt("uint %s[%lld];", mname.c_str(), (long long)words));
			for (size_t k = 0; k < init.size(); k++)
				if (init[k]) initlines.push_back(fmt("    %s[%zu] = %uu;", mname.c_str(), k, init[k]));
		}
		mems[name] = m;
		return GV::ptr(m, Off{}, vt);
	}

	std::vector<uint32_t> constWords(Constant *c, Type *t)
	{
		std::vector<uint8_t> buf((size_t)asize(t) + 4, 0);
		pack(buf, 0, c, t);
		std::vector<uint32_t> w((size_t)(asize(t) + 3) / 4);
		memcpy(w.data(), buf.data(), w.size() * 4);
		return w;
	}
	void pack(std::vector<uint8_t> &b, int64_t off, Constant *c, Type *t)
	{
		if (!c || isa<UndefValue>(c) || isa<ConstantAggregateZero>(c) || isa<ConstantPointerNull>(c)) return;
		if (auto *ci = dyn_cast<ConstantInt>(c)) {
			uint64_t v = ci->getZExtValue();
			unsigned n = std::max(1u, ci->getBitWidth() / 8);
			for (unsigned i = 0; i < n; i++) b[off + i] = (uint8_t)(v >> (8 * i));
			return;
		}
		if (auto *cf = dyn_cast<ConstantFP>(c)) {
			APInt bits = cf->getValueAPF().bitcastToAPInt();
			uint64_t v = bits.getZExtValue();
			unsigned n = bits.getBitWidth() / 8;
			for (unsigned i = 0; i < n; i++) b[off + i] = (uint8_t)(v >> (8 * i));
			return;
		}
		if (auto *st = dyn_cast<StructType>(t)) {
			for (unsigned i = 0; i < st->getNumElements(); i++)
				pack(b, off + foff(st, i), c->getAggregateElement(i), st->getElementType(i));
			return;
		}
		if (isVec(t) || t->isArrayTy()) {
			unsigned n = isVec(t) ? vn(t) : (unsigned)t->getArrayNumElements();
			Type *et = isVec(t) ? scal(t) : t->getArrayElementType();
			for (unsigned i = 0; i < n; i++) pack(b, off + i * estride(t), c->getAggregateElement(i), et);
			return;
		}
		fail("constant initializer");
	}

	/* ---- memory */
	std::string word(Mem &m, const Off &idx)
	{
		if (m.kind == "ubo") {
			auto &u = uboSize[m.name];
			if (idx.c) {
				u.first = std::max(u.first, idx.v / 4 + 1);
				return fmt("%s.w[%lld][%lld]", m.name.c_str(), (long long)(idx.v >> 2), (long long)(idx.v & 3));
			}
			u.second = true;
			return fmt("%s.w[(%s) >> 2][(%s) & 3]", m.name.c_str(), idx.e.c_str(), idx.e.c_str());
		}
		if (m.kind == "tbuf") return fmt("texelFetch(%s, %s).x", m.name.c_str(), idx.str().c_str());
		if (m.kind == "ssbo") return fmt("%s.w[%s]", m.name.c_str(), idx.str().c_str());
		if (m.kind == "array") {
			if (idx.c && idx.v >= m.words) return "0u";     /* default globals: dead branches only */
			return fmt("%s[%s]", m.name.c_str(), idx.str().c_str());
		}
		fail("read of " + m.kind);
	}
	static Off widx(const Off &o)
	{
		Off w;
		if (o.c) { w.v = o.v >> 2; return w; }
		w.c = false; w.e = "((" + o.e + ") >> 2)"; return w;
	}

	std::string load(const GV &p, Type *t)
	{
		if (p.k == GV::Choice) {
			std::vector<std::string> e;
			for (auto &o : *p.opts) e.push_back(load(o, t));
			return p.pick(e);
		}
		Mem &m = *p.mem;
		if (m.kind == "fc") {
			usesFc.insert({m.index, m.code});
			if (t->isIntegerTy(1)) return fmt("(FC%d != 0)", m.index);
			if (t->isFloatingPointTy() || isVec(t)) return fmt("%s(FC%d)", gty(t).c_str(), m.index);
			return fmt("int(FC%d)", m.index);
		}
		if (m.kind == "null") return zero(t);
		return loadTyped(p, t);
	}
	std::string loadTyped(const GV &p, Type *t)
	{
		if (isVec(t)) {
			std::vector<std::string> v;
			for (unsigned i = 0; i < vn(t); i++) v.push_back(loadTyped(p.add(Off{true, (int64_t)i * estride(t)}), scal(t)));
			return gty(t) + "(" + join(v) + ")";
		}
		if (auto *st = dyn_cast<StructType>(t)) {
			std::vector<std::string> v;
			for (unsigned i = 0; i < st->getNumElements(); i++)
				v.push_back(loadTyped(p.add(Off{true, foff(st, i)}), st->getElementType(i)));
			return gty(t) + "(" + join(v) + ")";
		}
		if (auto *at = dyn_cast<ArrayType>(t)) {
			std::vector<std::string> v;
			for (unsigned i = 0; i < at->getNumElements(); i++)
				v.push_back(loadTyped(p.add(Off{true, (int64_t)i * estride(t)}), at->getElementType()));
			return fmt("%s(%s[%zu](%s))", gty(t).c_str(), gty(at->getElementType()).c_str(), v.size(), join(v).c_str());
		}
		const Off &off = p.off;
		unsigned size = std::max(1u, bitsOf(t) / 8);
		std::string w = word(*p.mem, widx(off));
		if (size == 4) return t->isFloatingPointTy() ? "uintBitsToFloat(" + w + ")" : "int(" + w + ")";
		std::string sh = off.c ? std::to_string((off.v & 3) * 8) : "(((" + off.e + ") & 3) * 8)";
		std::string bits = (off.c && (off.v & 3) == 0) ? "(" + w + ")" : "((" + w + ") >> " + sh + ")";
		if (t->isHalfTy()) return "unpackHalf2x16(" + bits + ").x";
		if (t->isIntegerTy()) {
			unsigned b = bitsOf(t);
			uint64_t mask = b > 1 ? (1ull << b) - 1 : 0xff;
			std::string v = fmt("int(%s & %lluu)", bits.c_str(), (unsigned long long)mask);
			return b == 1 ? "(" + v + " != 0)" : v;
		}
		fail("load of type");
	}

	void store(const GV &p, const std::string &value, Type *t)
	{
		if (p.k == GV::Choice) {
			std::string tm = newt("cs");
			emit(gty(t) + " " + tm + " = " + value + ";");
			for (size_t k = 0; k < p.opts->size(); k++) {
				emit(fmt("if ((%s) == %zu) {", p.sel.c_str(), k)); depth++;
				store((*p.opts)[k], tm, t);
				depth--; emit("}");
			}
			return;
		}
		Mem &m = *p.mem;
		if (m.kind == "array") m.writable = true;
		else if (m.kind != "ssbo") fail("store to " + m.kind);
		if (isVec(t)) {
			std::string tm = newt("sv");
			emit(gty(t) + " " + tm + " = " + value + ";");
			for (unsigned i = 0; i < vn(t); i++) store(p.add(Off{true, (int64_t)i * estride(t)}), fmt("%s[%u]", tm.c_str(), i), scal(t));
			return;
		}
		if (auto *st = dyn_cast<StructType>(t)) {
			std::string tm = newt("ss");
			emit(gty(t) + " " + tm + " = " + value + ";");
			for (unsigned i = 0; i < st->getNumElements(); i++)
				store(p.add(Off{true, foff(st, i)}), fmt("%s.f%u", tm.c_str(), i), st->getElementType(i));
			return;
		}
		std::string w = word(m, widx(p.off));
		unsigned size = std::max(1u, bitsOf(t) / 8);
		if (size == 4) {
			emit(w + " = " + (t->isFloatingPointTy() ? "floatBitsToUint(" + value + ")" : "uint(" + value + ")") + ";");
			return;
		}
		std::string sh = p.off.c ? std::to_string((p.off.v & 3) * 8) : "(((" + p.off.e + ") & 3) * 8)";
		std::string bits;
		uint64_t mask;
		if (t->isFloatingPointTy()) { bits = "(packHalf2x16(vec2(" + value + ", 0.0)) & 0xffffu)"; mask = 0xffff; }
		else {
			unsigned b = bitsOf(t);
			mask = b > 1 ? (1ull << b) - 1 : 0xff;
			bits = fmt("(uint(%s) & %lluu)", b == 1 ? ("int(" + value + ")").c_str() : value.c_str(), (unsigned long long)mask);
		}
		emit(fmt("%s = (%s & ~(%lluu << %s)) | (%s << %s);", w.c_str(), w.c_str(), (unsigned long long)mask, sh.c_str(), bits.c_str(), sh.c_str()));
	}

	Off scaled(Value *v, int64_t size)
	{
		if (auto *ci = dyn_cast<ConstantInt>(v)) return Off{true, ci->getSExtValue() * size};
		if (isa<UndefValue>(v) || isa<ConstantAggregateZero>(v)) return Off{};
		Off o; o.c = false; o.e = fmt("(int(%s) * %lld)", ex(v).c_str(), (long long)size);
		return o;
	}
	GV doGep(const GV &base, Type *src, const std::vector<Value *> &idx)
	{
		if (base.k == GV::Choice) {
			std::vector<GV> o;
			for (auto &e : *base.opts) o.push_back(doGep(e, src, idx));
			return GV::choice(base.sel, o);
		}
		if (base.k != GV::Ptr) fail("gep on non-pointer");
		if (base.mem->kind == "texture" || base.mem->kind == "sampler" || base.mem->kind == "fc") return base;
		GV p = base.add(scaled(idx[0], asize(src)));
		Type *t = src;
		for (size_t k = 1; k < idx.size(); k++) {
			if (auto *st = dyn_cast<StructType>(t)) {
				unsigned f = (unsigned)cast<ConstantInt>(idx[k])->getZExtValue();
				p = p.add(Off{true, foff(st, f)}); t = st->getElementType(f);
			} else {
				p = p.add(scaled(idx[k], estride(t)));
				t = isVec(t) ? scal(t) : t->getArrayElementType();
			}
		}
		p.elem = t;
		return p;
	}

	/* ---- definitions */
	std::string vname(const Value *v)
	{
		auto it = names.find(v);
		if (it != names.end()) return it->second;
		std::string n = prefix + fmt("v%d", ++nameSeq);
		names[v] = n;
		return n;
	}
	void define(Instruction &I, const std::string &e)
	{
		std::string n = vname(&I);
		if (!declared.count(n)) {
			declared.insert(n);
			decls.push_back(gty(I.getType()) + " " + n + ";");
		}
		emit(n + " = " + e + ";");
		vals[&I] = GV::expr(n);
	}

	/* ---- control flow */
	void emitBody(Function &fn);
	void edge(BasicBlock *src, BasicBlock *dst, int mode, std::map<const BasicBlock *, int> *index);
	void block(BasicBlock &b, int mode, std::map<const BasicBlock *, int> *index);
	std::string flag(const BasicBlock *b) { return prefix + fmt("r%d", blockId(b)); }
	std::map<const BasicBlock *, int> blockIds;
	int blockId(const BasicBlock *b)
	{
		auto it = blockIds.find(b);
		if (it != blockIds.end()) return it->second;
		int n = (int)blockIds.size();
		blockIds[b] = n;
		return n;
	}

	/* ---- entry */
	void setupArgs(const std::vector<MI> &args);
	bool writesParam(Argument *a);
	std::string inTy(Type *t)
	{
		if (t->isFloatingPointTy() || (isVec(t) && scal(t)->isFloatingPointTy())) return gty(t);
		if (t->isIntegerTy()) return "int";
		if (isVec(t)) return fmt("ivec%u", vn(t));
		fail("input type");
	}
	void ret(ReturnInst &R);

	/* ---- instructions */
	void inst(Instruction &I);
	std::string binop(unsigned op, Type *t, const std::string &x, const std::string &y);
	std::string wrap(const std::string &r, unsigned bits) { return bits >= 32 ? r : fmt("(%s & %llu)", r.c_str(), (unsigned long long)((1ull << bits) - 1)); }
	std::string zx(const std::string &x, unsigned bits) { return wrap(x, bits); }
	std::string sx(const std::string &x, unsigned bits)
	{
		if (bits >= 32) return x;
		unsigned s = 32 - bits;
		return fmt("((%s << %u) >> %u)", x.c_str(), s, s);
	}
	std::string compare(CmpInst &C);
	void castI(CastInst &C);
	std::string bitcastE(const std::string &x, Type *src, Type *t);
	void shuffle(ShuffleVectorInst &S);
	void call(CallInst &C);
	void convert(CallInst &C, const std::string &name);
	std::string combined(const GV &tex, const GV *smp);
	std::string perTexture(const GV &tex, const std::function<std::string(const GV &)> &f, const std::string &null);
	void sample(CallInst &C);
	std::string sampleExpr(CallInst &C, const GV &tex, const GV &smp, const std::string &coord);
	std::string paren(const std::string &x)
	{
		for (char c : x) if (!(isalnum((unsigned char)c) || c == '_' || c == '.')) return "(" + x + ")";
		return x;
	}
	std::string aggPath(std::string s, Type *t, ArrayRef<unsigned> idx)
	{
		s = paren(s);
		for (unsigned k : idx) {
			if (auto *st = dyn_cast<StructType>(t)) { s += fmt(".f%u", k); t = st->getElementType(k); }
			else if (t->isArrayTy()) { s += fmt(".e[%u]", k); t = t->getArrayElementType(); }
			else { s += fmt("[%u]", k); t = scal(t); }
		}
		return s;
	}
	void assemble();
};

/* ---------------------------------------------------------------- control flow */

static bool cfgOrder(Function &fn, std::vector<BasicBlock *> &order)
{
	std::map<BasicBlock *, int> state;
	std::vector<BasicBlock *> post;
	bool cyclic = false;
	std::vector<std::pair<BasicBlock *, unsigned>> stack;
	BasicBlock *entry = &fn.getEntryBlock();
	stack.push_back({entry, 0});
	state[entry] = 1;
	while (!stack.empty()) {
		auto &top = stack.back();
		Instruction *term = top.first->getTerminator();
		if (top.second >= term->getNumSuccessors()) {
			state[top.first] = 2;
			post.push_back(top.first);
			stack.pop_back();
			continue;
		}
		BasicBlock *n = term->getSuccessor(top.second++);
		auto it = state.find(n);
		if (it != state.end() && it->second == 1) cyclic = true;
		else if (it == state.end()) { state[n] = 1; stack.push_back({n, 0}); }
	}
	order.assign(post.rbegin(), post.rend());
	return cyclic;
}

void Translator::emitBody(Function &fn)
{
	std::vector<BasicBlock *> blocks;
	bool cyclic = cfgOrder(fn, blocks);
	std::map<const BasicBlock *, int> index;
	for (size_t i = 0; i < blocks.size(); i++) index[blocks[i]] = (int)i;
	phis.clear();
	for (BasicBlock *b : blocks)
		for (PHINode &p : b->phis()) {
			std::string n = vname(&p);
			declared.insert(n);
			if (p.getType()->isPointerTy()) {
				decls.push_back("int " + n + " = 0;");
				vals[&p] = GV::choice(n, {});
			} else {
				decls.push_back(gty(p.getType()) + " " + n + ";");
				vals[&p] = GV::expr(n);
			}
			phis[b].push_back(&p);
		}
	if (blocks.size() == 1) {
		block(*blocks[0], 0, nullptr);
	} else if (!cyclic) {
		for (size_t k = 1; k < blocks.size(); k++) decls.push_back("bool " + flag(blocks[k]) + " = false;");
		for (size_t k = 0; k < blocks.size(); k++) {
			if (k) { emit("if (" + flag(blocks[k]) + ") {"); depth++; }
			block(*blocks[k], 1, nullptr);
			if (k) { depth--; emit("}"); }
		}
	} else {
		std::string bb = prefix + "bb";
		decls.push_back("int " + bb + " = 0;");
		emit(fmt("for (int g_%s = 0; g_%s < 100000 && %s >= 0; g_%s++) {", bb.c_str(), bb.c_str(), bb.c_str(), bb.c_str()));
		depth++;
		for (size_t k = 0; k < blocks.size(); k++) {
			emit(fmt("%sif (%s == %zu) {", k ? "else " : "", bb.c_str(), k)); depth++;
			block(*blocks[k], 2, &index);
			depth--; emit("}");
		}
		depth--; emit("}");
	}
}

void Translator::edge(BasicBlock *src, BasicBlock *dst, int mode, std::map<const BasicBlock *, int> *index)
{
	struct Copy { std::string dst, e; Type *t; };
	std::vector<Copy> copies;
	for (PHINode *p : phis[dst]) {
		Value *in = p->getIncomingValueForBlock(src);
		if (p->getType()->isPointerTy()) {
			GV &ch = vals[p];
			ch.opts->push_back(val(in, p->getType()));
			emit(fmt("%s = %zu;", ch.sel.c_str(), ch.opts->size() - 1));
			continue;
		}
		copies.push_back({vals[p].e, ex(in, p->getType()), p->getType()});
	}
	if (copies.size() > 1) {
		std::vector<std::pair<std::string, std::string>> t;
		for (auto &c : copies) {
			std::string tv = newt("pc");
			emit(gty(c.t) + " " + tv + " = " + c.e + ";");
			t.push_back({c.dst, tv});
		}
		for (auto &x : t) emit(x.first + " = " + x.second + ";");
	} else {
		for (auto &c : copies) emit(c.dst + " = " + c.e + ";");
	}
	if (mode == 1) emit(flag(dst) + " = true;");
	else if (mode == 2) emit(fmt("%sbb = %d;", prefix.c_str(), (*index)[dst]));
}

void Translator::block(BasicBlock &b, int mode, std::map<const BasicBlock *, int> *index)
{
	for (Instruction &I : b) {
		if (isa<PHINode>(I)) continue;
		if (auto *br = dyn_cast<BranchInst>(&I)) {
			if (br->isUnconditional()) { edge(&b, br->getSuccessor(0), mode, index); continue; }
			emit("if (" + ex(br->getCondition()) + ") {"); depth++;
			edge(&b, br->getSuccessor(0), mode, index);
			depth--; emit("} else {"); depth++;
			edge(&b, br->getSuccessor(1), mode, index);
			depth--; emit("}");
		} else if (auto *sw = dyn_cast<SwitchInst>(&I)) {
			std::string v = ex(sw->getCondition());
			unsigned bits = sw->getCondition()->getType()->getIntegerBitWidth();
			bool first = true;
			for (auto &cs : sw->cases()) {
				emit(fmt("%sif (%s == %s) {", first ? "" : "} else ", v.c_str(), ilit(cs.getCaseValue()->getSExtValue(), bits).c_str()));
				first = false;
				depth++; edge(&b, cs.getCaseSuccessor(), mode, index); depth--;
			}
			emit(first ? "{" : "} else {"); depth++;
			edge(&b, sw->getDefaultDest(), mode, index);
			depth--; emit("}");
		} else if (auto *r = dyn_cast<ReturnInst>(&I)) {
			ret(*r);
			if (mode == 2) emit(prefix + "bb = -1;");
		} else if (isa<UnreachableInst>(I)) {
			if (mode == 2) emit(prefix + "bb = -1;");
		} else {
			inst(I);
		}
	}
}

/* ---------------------------------------------------------------- entry */

bool Translator::writesParam(Argument *a)
{
	auto base = [](Value *v) {
		for (int k = 0; k < 64; k++) {
			if (auto *g = dyn_cast<GEPOperator>(v)) v = g->getPointerOperand();
			else if (auto *c = dyn_cast<BitCastOperator>(v)) v = c->getOperand(0);
			else if (auto *o = dyn_cast<Operator>(v); o && o->getOpcode() == Instruction::AddrSpaceCast) v = o->getOperand(0);
			else break;
		}
		return v;
	};
	for (BasicBlock &b : F)
		for (Instruction &I : b) {
			if (auto *s = dyn_cast<StoreInst>(&I)) if (base(s->getPointerOperand()) == a) return true;
			if (auto *c = dyn_cast<CallInst>(&I))
				if (c->getCalledFunction() && c->getCalledFunction()->getName().contains("write") && c->arg_size() && base(c->getArgOperand(0)) == a)
					return true;
		}
	return false;
}

void Translator::setupArgs(const std::vector<MI> &args)
{
	for (const MI &item : args) {
		if (item.k != MI::List || item.l.empty() || item.l[0].k != MI::Int) continue;
		int64_t k = item.l[0].i;
		if (k < 0 || k >= (int64_t)F.arg_size()) fail("argument index");
		Argument *A = F.getArg((unsigned)k);
		Type *pt = A->getType();
		std::string pred;
		std::vector<MI> rest = strip_pred(std::vector<MI>(item.l.begin() + 1, item.l.end()), &pred);
		if (rest.empty() || rest[0].k != MI::Str) fail("argument metadata");
		std::string kind = rest[0].s;
		std::string argname = attr_str(rest, "air.arg_name");
		if (argname.empty()) argname = fmt("a%lld", (long long)k);
		std::string predj = pred.empty() ? "null" : J::q(pred);
		if (kind == "air.vertex_input") {
			int64_t loc = attr_int(rest, "air.location_index");
			std::string var = "in_" + sanitize(argname);
			gout.push_back(fmt("layout(location = %lld) in %s %s;", (long long)loc, inTy(pt).c_str(), var.c_str()));
			vals[A] = GV::expr(pt->isIntegerTy(1) ? "(" + var + " != 0)" : var);
			rInputs.push_back(fmt("{\"location\": %lld, \"type\": %s, \"name\": %s}", (long long)loc, J::q(gty(pt)).c_str(), J::q(argname).c_str()));
		} else if (kind == "air.vertex_id") vals[A] = GV::expr("gl_VertexID");
		else if (kind == "air.instance_id") vals[A] = GV::expr("gl_InstanceID");
		else if (kind == "air.base_vertex" || kind == "air.base_instance" || kind == "air.sample_id") vals[A] = GV::expr("0");
		else if (kind == "air.position" && stage == "fragment") {
			vals[A] = GV::expr("vec4(gl_FragCoord.x, T290_FRAG_Y(gl_FragCoord.y), gl_FragCoord.z, 1.0 / gl_FragCoord.w)");
			needRtHeight = true;
		} else if (kind == "air.fragment_input") {
			std::string gen = rest.size() > 1 ? rest[1].s : argname;
			std::string key = varying_key(gen);
			bool integer = pt->isIntegerTy() || (isVec(pt) && scal(pt)->isIntegerTy());
			bool flat = has(rest, "air.flat") || integer;
			gout.push_back(fmt("%sin %s vy_%s;", flat ? "flat " : "", inTy(pt).c_str(), key.c_str()));
			std::string var = "vy_" + key;
			vals[A] = GV::expr(pt->isIntegerTy(1) ? "(" + var + " != 0)" : var);
			rInputs.push_back(fmt("{\"varying\": %s, \"type\": %s, \"key\": %s, \"interp\": %s}", J::q(gen).c_str(),
			    J::q(gty(pt)).c_str(), J::q(key).c_str(), flat ? "\"flat\"" : "\"smooth\""));
		} else if (kind == "air.render_target" && stage == "fragment") {
			int64_t rt = rest.size() > 1 && rest[1].k == MI::Int ? rest[1].i : 0;
			std::string var = fmt("T290_FB%lld", (long long)rt);
			bool seen = false;
			for (int64_t x : fbInputs) seen |= x == rt;
			if (!seen) { gout.push_back("uniform highp sampler2D " + var + ";"); fbInputs.push_back(rt); }
			std::string e = "texelFetch(" + var + ", ivec2(gl_FragCoord.xy), 0)";
			unsigned n = isVec(pt) ? vn(pt) : 1;
			vals[A] = GV::expr(n == 4 ? e : e + "." + std::string("xyzw").substr(0, n));
		} else if (kind == "air.front_facing") vals[A] = GV::expr("gl_FrontFacing");
		else if (kind == "air.point_coord") vals[A] = GV::expr("gl_PointCoord");
		else if (kind == "air.buffer") {
			int64_t idx = attr_int(rest, "air.location_index");
			int64_t space = attr_int(rest, "air.address_space");
			bool writes = has(rest, "air.read_write") || has(rest, "air.write");
			bool written = writes && writesParam(A);
			auto m = std::make_shared<Mem>();
			if (space == 2) {
				m->kind = "ubo"; m->name = fmt("B%lld_U", (long long)idx);
				int64_t size = attr_int(rest, "air.buffer_size", -1);
				if (size < 0) size = attr_int(rest, "air.arg_type_size", 16);
				gout.push_back(fmt("layout(std140) uniform %s_blk { uvec4 w[@UBO_%s@]; } %s;", m->name.c_str(), m->name.c_str(), m->name.c_str()));
				uboSize[m->name] = {(size + 15) / 16, false};
			} else if (written) {
				if (stage == "vertex") fail("vertex stage writes a device buffer");
				m->kind = "ssbo"; m->name = fmt("B%lld_S", (long long)idx); m->writable = true;
				gout.push_back(fmt("layout(std430) buffer %s_blk { uint w[]; } %s;", m->name.c_str(), m->name.c_str()));
			} else {
				m->kind = "tbuf"; m->name = fmt("B%lld_T", (long long)idx);
				gout.push_back("uniform highp usamplerBuffer " + m->name + ";");
				needTbuf = true;
			}
			vals[A] = GV::ptr(m, Off{}, pt->getPointerElementType());
			rBuffers.push_back(fmt("{\"index\": %lld, \"kind\": %s, \"name\": %s, \"space\": %lld, \"pred\": %s@UBOBYTES_%s@}",
			    (long long)idx, J::q(m->kind).c_str(), J::q(m->name).c_str(), (long long)space, predj.c_str(), m->name.c_str()));
		} else if (kind == "air.texture") {
			int64_t idx = attr_int(rest, "air.location_index");
			std::string tname = attr_str(rest, "air.arg_type_name");
			auto m = std::make_shared<Mem>(); m->kind = "texture"; m->name = fmt("T%lld", (long long)idx); m->index = (int)idx;
			m->dim = tname.find("3d") != std::string::npos ? "3d" : "2d";
			vals[A] = GV::ptr(m, Off{}, nullptr);
			rTextures.push_back(fmt("{\"index\": %lld, \"type\": %s, \"dim\": %s, \"pred\": %s}", (long long)idx, J::q(tname).c_str(),
			    J::q(m->dim).c_str(), predj.c_str()));
		} else if (kind == "air.sampler") {
			int64_t idx = attr_int(rest, "air.location_index");
			auto m = std::make_shared<Mem>(); m->kind = "sampler"; m->name = fmt("S%lld", (long long)idx); m->index = (int)idx;
			vals[A] = GV::ptr(m, Off{}, nullptr);
			rSamplers.push_back(fmt("{\"index\": %lld}", (long long)idx));
		} else if (kind == "air.threads_per_threadgroup" || kind == "air.threadgroups_per_grid" ||
		           kind == "air.thread_position_in_grid" || kind == "air.thread_position_in_threadgroup" ||
		           kind == "air.threadgroup_position_in_grid" || kind == "air.thread_index_in_threadgroup") {
			std::string g = kind == "air.threads_per_threadgroup" ? "gl_WorkGroupSize" :
			    kind == "air.threadgroups_per_grid" ? "gl_NumWorkGroups" :
			    kind == "air.thread_position_in_grid" ? "gl_GlobalInvocationID" :
			    kind == "air.thread_position_in_threadgroup" ? "gl_LocalInvocationID" :
			    kind == "air.threadgroup_position_in_grid" ? "gl_WorkGroupID" : "gl_LocalInvocationIndex";
			if (isVec(pt)) vals[A] = GV::expr(fmt("ivec%u(%s%s)", vn(pt), g.c_str(), vn(pt) == 2 ? ".xy" : ""));
			else vals[A] = GV::expr("int(" + g + (g == "gl_LocalInvocationIndex" ? "" : ".x") + ")");
		} else {
			fail("argument kind " + kind);
		}
	}
}

void Translator::ret(ReturnInst &R)
{
	Value *rv = R.getReturnValue();
	if (!rv) return;
	Type *t = rv->getType();
	std::string tm = newt("rv");
	emit(gty(t) + " " + tm + " = " + ex(rv) + ";");
	std::vector<std::pair<std::string, Type *>> fields;
	if (auto *st = dyn_cast<StructType>(t))
		for (unsigned i = 0; i < st->getNumElements(); i++) fields.push_back({fmt("%s.f%u", tm.c_str(), i), st->getElementType(i)});
	else fields.push_back({tm, t});
	if (fields.size() != outMeta.size()) fail("output count mismatch");
	for (size_t k = 0; k < fields.size(); k++) {
		const std::string &e = fields[k].first;
		Type *ft = fields[k].second;
		std::string pred;
		std::vector<MI> rest = strip_pred(outMeta[k].l, &pred);
		std::string kind = rest.empty() ? "" : rest[0].s;
		std::string predj = pred.empty() ? "null" : J::q(pred);
		if (kind == "air.position") {
			emit(fmt("gl_Position = vec4(%s.x, -(%s.y), 2.0 * %s.z - %s.w, %s.w);", e.c_str(), e.c_str(), e.c_str(), e.c_str(), e.c_str()));
		} else if (kind == "air.point_size") {
			emit("gl_PointSize = " + e + ";");
		} else if (kind == "air.vertex_output") {
			std::string gen = rest.size() > 1 ? rest[1].s : "";
			std::string key = varying_key(gen);
			std::string var = "vy_" + key;
			bool seen = false;
			for (auto &g : gout) seen |= g.find(" " + var + ";") != std::string::npos;
			if (!seen) {
				bool integer = ft->isIntegerTy() || (isVec(ft) && scal(ft)->isIntegerTy());
				if (!integer) gout.push_back(fmt("#ifndef T290_Q_%s\n#define T290_Q_%s\n#endif", key.c_str(), key.c_str()));
				gout.push_back(fmt("%s out %s %s;", integer ? "flat" : ("T290_Q_" + key).c_str(), inTy(ft).c_str(), var.c_str()));
				rOutputs.push_back(fmt("{\"varying\": %s, \"key\": %s, \"type\": %s, \"pred\": %s}", J::q(gen).c_str(), J::q(key).c_str(),
				    J::q(gty(ft)).c_str(), predj.c_str()));
			}
			emit(var + " = " + (ft->isIntegerTy(1) ? "int(" + e + ")" : e) + ";");
		} else if (kind == "air.render_target") {
			int64_t rt = rest.size() > 1 && rest[1].k == MI::Int ? rest[1].i : 0;
			std::string var = fmt("o_rt%lld", (long long)rt);
			bool seen = false;
			for (auto &g : gout) seen |= g.find(" " + var + ";") != std::string::npos;
			if (!seen) {
				gout.push_back(fmt("layout(location = %lld) out vec4 %s;", (long long)rt, var.c_str()));
				rOutputs.push_back(fmt("{\"render_target\": %lld, \"type\": %s}", (long long)rt, J::q(gty(ft)).c_str()));
			}
			unsigned n = isVec(ft) ? vn(ft) : 1;
			std::string v = e;
			if (n != 4) {
				v = "vec4(" + e;
				for (unsigned z = n; z < 3; z++) v += ", 0.0";
				v += ", 1.0)";
			}
			emit(var + " = " + v + ";");
		} else if (kind == "air.depth") {
			emit("gl_FragDepth = " + e + ";");
		} else if (kind == "air.sample_mask") {
		} else {
			fail("output kind " + kind);
		}
	}
}

/* ---------------------------------------------------------------- instructions */

std::string Translator::binop(unsigned op, Type *t, const std::string &x, const std::string &y)
{
	bool v = isVec(t);
	Type *et = scal(t);
	if (et->isFloatingPointTy()) {
		switch (op) {
		case Instruction::FAdd: return "(" + x + " + " + y + ")";
		case Instruction::FSub: return "(" + x + " - " + y + ")";
		case Instruction::FMul: return "(" + x + " * " + y + ")";
		case Instruction::FDiv: return "(" + x + " / " + y + ")";
		case Instruction::FRem: return "mod(" + x + ", " + y + ")";
		}
		fail("float op");
	}
	unsigned bits = bitsOf(et);
	if (bits == 1) {
		if (v) {
			std::vector<std::string> c;
			if (op == Instruction::Xor) return "notEqual(" + x + ", " + y + ")";
			for (unsigned k = 0; k < vn(t); k++)
				c.push_back(fmt("%s[%u] %s %s[%u]", x.c_str(), k, op == Instruction::And ? "&&" : "||", y.c_str(), k));
			if (op != Instruction::And && op != Instruction::Or) fail("i1 vector op");
			return gty(t) + "(" + join(c) + ")";
		}
		if (op == Instruction::And) return "(" + x + " && " + y + ")";
		if (op == Instruction::Or) return "(" + x + " || " + y + ")";
		if (op == Instruction::Xor) return "(" + x + " != " + y + ")";
		fail("i1 op");
	}
	std::string u = v ? fmt("uvec%u", vn(t)) : "uint", i_ = gty(t);
	switch (op) {
	case Instruction::Add: return wrap("(" + x + " + " + y + ")", bits);
	case Instruction::Sub: return wrap("(" + x + " - " + y + ")", bits);
	case Instruction::Mul: return wrap("(" + x + " * " + y + ")", bits);
	case Instruction::And: return "(" + x + " & " + y + ")";
	case Instruction::Or: return "(" + x + " | " + y + ")";
	case Instruction::Xor: return "(" + x + " ^ " + y + ")";
	case Instruction::Shl: return wrap("(" + x + " << " + y + ")", bits);
	case Instruction::LShr: return i_ + "(" + u + "(" + zx(x, bits) + ") >> " + u + "(" + y + "))";
	case Instruction::AShr: return "(" + sx(x, bits) + " >> " + y + ")";
	case Instruction::SDiv: return "(" + sx(x, bits) + " / " + sx(y, bits) + ")";
	case Instruction::SRem: return "(" + sx(x, bits) + " - (" + sx(x, bits) + " / " + sx(y, bits) + ") * " + sx(y, bits) + ")";
	case Instruction::UDiv: return i_ + "(" + u + "(" + zx(x, bits) + ") / " + u + "(" + zx(y, bits) + "))";
	case Instruction::URem: return i_ + "(" + u + "(" + zx(x, bits) + ") % " + u + "(" + zx(y, bits) + "))";
	}
	fail("integer op");
}

std::string Translator::compare(CmpInst &C)
{
	Type *t = C.getOperand(0)->getType();
	std::string x = ex(C.getOperand(0)), y = ex(C.getOperand(1));
	bool v = isVec(t);
	unsigned n = v ? vn(t) : 1;
	auto P = C.getPredicate();
	static const char *syms[] = {"==", "!=", "<", "<=", ">", ">="};
	static const char *fns[] = {"equal", "notEqual", "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual"};
	auto out = [&](int b, const std::string &a, const std::string &c) {
		return v ? fmt("%s(%s, %s)", fns[b], a.c_str(), c.c_str()) : fmt("(%s %s %s)", a.c_str(), syms[b], c.c_str());
	};
	if (C.isFPPredicate()) {
		if (P == CmpInst::FCMP_TRUE) return v ? fmt("bvec%u(true)", n) : "true";
		if (P == CmpInst::FCMP_FALSE) return v ? fmt("bvec%u(false)", n) : "false";
		auto vor = [&](const std::string &a, const std::string &b) {
			std::vector<std::string> c;
			for (unsigned k = 0; k < n; k++) c.push_back(fmt("(%s[%u] || %s[%u])", a.c_str(), k, b.c_str(), k));
			return fmt("bvec%u(%s)", n, join(c).c_str());
		};
		if (P == CmpInst::FCMP_ORD) return v ? "not(" + vor("isnan(" + x + ")", "isnan(" + y + ")") + ")" : "!(isnan(" + x + ") || isnan(" + y + "))";
		if (P == CmpInst::FCMP_UNO) return v ? vor("isnan(" + x + ")", "isnan(" + y + ")") : "(isnan(" + x + ") || isnan(" + y + "))";
		int b;
		switch (P) {
		case CmpInst::FCMP_OEQ: case CmpInst::FCMP_UEQ: b = 0; break;
		case CmpInst::FCMP_ONE: case CmpInst::FCMP_UNE: b = 1; break;
		case CmpInst::FCMP_OLT: case CmpInst::FCMP_ULT: b = 2; break;
		case CmpInst::FCMP_OLE: case CmpInst::FCMP_ULE: b = 3; break;
		case CmpInst::FCMP_OGT: case CmpInst::FCMP_UGT: b = 4; break;
		default: b = 5; break;
		}
		return out(b, x, y);      /* fast-math shaders: NaN ordering dropped */
	}
	unsigned bits = bitsOf(scal(t));
	if (bits == 1) {
		if (P == CmpInst::ICMP_EQ || P == CmpInst::ICMP_NE) return out(P == CmpInst::ICMP_EQ ? 0 : 1, x, y);
		x = v ? fmt("ivec%u(%s)", n, x.c_str()) : "int(" + x + ")";
		y = v ? fmt("ivec%u(%s)", n, y.c_str()) : "int(" + y + ")";
	}
	int b;
	switch (P) {
	case CmpInst::ICMP_EQ: b = 0; break;
	case CmpInst::ICMP_NE: b = 1; break;
	case CmpInst::ICMP_ULT: case CmpInst::ICMP_SLT: b = 2; break;
	case CmpInst::ICMP_ULE: case CmpInst::ICMP_SLE: b = 3; break;
	case CmpInst::ICMP_UGT: case CmpInst::ICMP_SGT: b = 4; break;
	default: b = 5; break;
	}
	if (C.isUnsigned()) {
		std::string u = v ? fmt("uvec%u", n) : "uint";
		x = u + "(" + zx(x, bits) + ")";
		y = u + "(" + zx(y, bits) + ")";
	} else if (C.isSigned()) {
		x = sx(x, bits); y = sx(y, bits);
	} else if (bits < 32 && bits != 1) {
		x = zx(x, bits); y = zx(y, bits);
	}
	return out(b, x, y);
}

std::string Translator::bitcastE(const std::string &x, Type *src, Type *t)
{
	if (src == t) return x;
	std::string tw = newt("bw");
	emit(gty(src) + " " + tw + " = " + x + ";");
	std::vector<std::pair<std::string, unsigned>> parts;
	auto sbits = [&](const std::string &e, Type *st) -> std::pair<std::string, unsigned> {
		if (st->isFloatingPointTy())
			return st->isFloatTy() ? std::make_pair("floatBitsToUint(" + e + ")", 32u) : std::make_pair("(packHalf2x16(vec2(" + e + ", 0.0)) & 0xffffu)", 16u);
		unsigned b = bitsOf(st);
		if (b == 32) return {"uint(" + e + ")", 32u};
		return {fmt("(uint(%s) & %lluu)", e.c_str(), (unsigned long long)((1ull << b) - 1)), b};
	};
	if (isVec(src)) for (unsigned k = 0; k < vn(src); k++) parts.push_back(sbits(fmt("%s[%u]", tw.c_str(), k), scal(src)));
	else parts.push_back(sbits(tw, src));
	std::vector<std::string> words;
	std::string cur;
	unsigned used = 0;
	for (auto &p : parts) {
		if (p.second == 32) { words.push_back(p.first); continue; }
		if (cur.empty()) { cur = "(" + p.first + ")"; used = p.second; }
		else { cur = fmt("(%s | (%s << %uu))", cur.c_str(), p.first.c_str(), used); used += p.second; }
		if (used == 32) { words.push_back(cur); cur.clear(); used = 0; }
	}
	if (!cur.empty()) words.push_back(cur);
	std::string tu = newt("bu");
	emit(fmt("uint %s[%zu] = uint[%zu](%s);", tu.c_str(), words.size(), words.size(), join(words).c_str()));
	Type *et = scal(t);
	unsigned n = isVec(t) ? vn(t) : 1, bits = bitsOf(et);
	std::vector<std::string> el;
	for (unsigned k = 0; k < n; k++) {
		unsigned bo = k * bits;
		std::string w = fmt("%s[%u]", tu.c_str(), bo / 32);
		std::string raw = bo % 32 ? fmt("(%s >> %uu)", w.c_str(), bo % 32) : w;
		if (et->isFloatingPointTy()) el.push_back(bits == 32 ? "uintBitsToFloat(" + raw + ")" : "unpackHalf2x16(" + raw + ").x");
		else el.push_back(bits == 32 ? "int(" + raw + ")" : fmt("int(%s & %lluu)", raw.c_str(), (unsigned long long)((1ull << bits) - 1)));
	}
	return n == 1 ? el[0] : gty(t) + "(" + join(el) + ")";
}

void Translator::castI(CastInst &C)
{
	Type *src = C.getSrcTy(), *t = C.getDestTy();
	GV x = val(C.getOperand(0), src);
	unsigned op = C.getOpcode();
	if (x.isPtr()) {
		if (op == Instruction::BitCast || op == Instruction::AddrSpaceCast) { vals[&C] = recast(x, t); return; }
		fail("pointer cast");
	}
	std::string e = x.e, g = gty(t);
	bool v = isVec(t);
	unsigned sb = bitsOf(scal(src)), tb = bitsOf(scal(t));
	switch (op) {
	case Instruction::FPExt: case Instruction::FPTrunc: define(C, e); return;
	case Instruction::ZExt: define(C, sb == 1 ? g + "(" + e + ")" : zx(e, sb)); return;
	case Instruction::SExt: define(C, sb == 1 ? "(-" + g + "(" + e + "))" : sx(e, sb)); return;
	case Instruction::Trunc:
		if (tb == 1) define(C, v ? fmt("notEqual(%s & 1, %s(0))", e.c_str(), gty(src).c_str()) : "((" + e + " & 1) != 0)");
		else define(C, wrap(e, tb));
		return;
	case Instruction::SIToFP: define(C, g + "(" + sx(e, sb) + ")"); return;
	case Instruction::UIToFP: define(C, g + "(" + (v ? fmt("uvec%u", vn(t)) : std::string("uint")) + "(" + (sb == 1 ? e : zx(e, sb)) + "))"); return;
	case Instruction::FPToSI: case Instruction::FPToUI: define(C, g + "(" + e + ")"); return;
	case Instruction::BitCast: define(C, bitcastE(e, src, t)); return;
	}
	fail(std::string("cast ") + C.getOpcodeName());
}

void Translator::shuffle(ShuffleVectorInst &S)
{
	Type *at = S.getOperand(0)->getType();
	unsigned n = vn(at);
	std::string xs = paren(ex(S.getOperand(0)));
	Value *b = S.getOperand(1);
	bool hasB = !(isa<UndefValue>(b) || isa<ConstantAggregateZero>(b));
	std::string ys = hasB ? paren(ex(b)) : "";
	std::vector<std::string> c;
	for (int m : S.getShuffleMask()) {
		if (m < 0) c.push_back(zero(scal(at)));
		else if ((unsigned)m < n) c.push_back(fmt("%s[%d]", xs.c_str(), m));
		else c.push_back(hasB ? fmt("%s[%u]", ys.c_str(), m - n) : zero(scal(at)));
	}
	define(S, c.size() == 1 ? c[0] : gty(S.getType()) + "(" + join(c) + ")");
}

void Translator::inst(Instruction &I)
{
	if (auto *bo = dyn_cast<BinaryOperator>(&I)) {
		define(I, binop(bo->getOpcode(), I.getType(), ex(I.getOperand(0)), ex(I.getOperand(1))));
	} else if (I.getOpcode() == Instruction::FNeg) {
		define(I, "(-(" + ex(I.getOperand(0)) + "))");
	} else if (auto *c = dyn_cast<CmpInst>(&I)) {
		define(I, compare(*c));
	} else if (auto *c = dyn_cast<CastInst>(&I)) {
		castI(*c);
	} else if (auto *s = dyn_cast<SelectInst>(&I)) {
		std::string cnd = ex(s->getCondition());
		GV x = val(s->getTrueValue(), I.getType()), y = val(s->getFalseValue(), I.getType());
		if (x.isPtr() || y.isPtr()) {
			if (x.k == GV::Ptr && y.k == GV::Ptr && x.mem == y.mem) {
				GV p = x; p.off.c = false;
				p.off.e = fmt("((%s) ? %s : %s)", cnd.c_str(), x.off.str().c_str(), y.off.str().c_str());
				vals[&I] = p;
				return;
			}
			vals[&I] = GV::choice("((" + cnd + ") ? 0 : 1)", {x, y});
			return;
		}
		if (isVec(s->getCondition()->getType())) {
			if (scal(I.getType())->isFloatingPointTy()) define(I, "mix(" + y.e + ", " + x.e + ", " + cnd + ")");
			else {
				std::vector<std::string> el;
				for (unsigned k = 0; k < vn(I.getType()); k++)
					el.push_back(fmt("(%s[%u] ? %s[%u] : %s[%u])", cnd.c_str(), k, x.e.c_str(), k, y.e.c_str(), k));
				define(I, gty(I.getType()) + "(" + join(el) + ")");
			}
		} else define(I, "((" + cnd + ") ? " + x.e + " : " + y.e + ")");
	} else if (auto *e = dyn_cast<ExtractElementInst>(&I)) {
		Value *ix = e->getIndexOperand();
		std::string is = isa<ConstantInt>(ix) ? std::to_string(cast<ConstantInt>(ix)->getZExtValue()) : "int(" + ex(ix) + ")";
		define(I, paren(ex(e->getVectorOperand())) + "[" + is + "]");
	} else if (auto *ie = dyn_cast<InsertElementInst>(&I)) {
		Value *ix = ie->getOperand(2);
		std::string is = isa<ConstantInt>(ix) ? std::to_string(cast<ConstantInt>(ix)->getZExtValue()) : "int(" + ex(ix) + ")";
		std::string tm = newt("ie");
		emit(gty(I.getType()) + " " + tm + " = " + ex(ie->getOperand(0), I.getType()) + ";");
		emit(tm + "[" + is + "] = " + ex(ie->getOperand(1), scal(I.getType())) + ";");
		define(I, tm);
	} else if (auto *sv = dyn_cast<ShuffleVectorInst>(&I)) {
		shuffle(*sv);
	} else if (auto *ev = dyn_cast<ExtractValueInst>(&I)) {
		define(I, aggPath(ex(ev->getAggregateOperand()), ev->getAggregateOperand()->getType(), ev->getIndices()));
	} else if (auto *iv = dyn_cast<InsertValueInst>(&I)) {
		std::string tm = newt("iv");
		emit(gty(I.getType()) + " " + tm + " = " + ex(iv->getAggregateOperand(), I.getType()) + ";");
		emit(aggPath(tm, I.getType(), iv->getIndices()) + " = " + ex(iv->getInsertedValueOperand()) + ";");
		define(I, tm);
	} else if (auto *ld = dyn_cast<LoadInst>(&I)) {
		GV p = val(ld->getPointerOperand());
		if (p.k == GV::Choice) {
			bool handles = true;
			for (auto &o : *p.opts) handles &= o.k == GV::Ptr && (o.mem->kind == "texture" || o.mem->kind == "sampler");
			if (handles) { vals[&I] = p; return; }
			define(I, load(p, I.getType()));
			return;
		}
		if (p.k != GV::Ptr) fail("load from non-pointer");
		if (p.mem->kind == "texture" || p.mem->kind == "sampler") { vals[&I] = p; return; }
		define(I, load(p, I.getType()));
	} else if (auto *st = dyn_cast<StoreInst>(&I)) {
		GV p = val(st->getPointerOperand());
		if (!p.isPtr()) fail("store to non-pointer");
		store(p, ex(st->getValueOperand()), st->getValueOperand()->getType());
	} else if (auto *g = dyn_cast<GetElementPtrInst>(&I)) {
		std::vector<Value *> idx(g->idx_begin(), g->idx_end());
		vals[&I] = doGep(val(g->getPointerOperand()), g->getSourceElementType(), idx);
	} else if (auto *a = dyn_cast<AllocaInst>(&I)) {
		int64_t count = 1;
		if (auto *ci = dyn_cast<ConstantInt>(a->getArraySize())) count = ci->getSExtValue();
		int64_t words = std::max<int64_t>(1, (asize(a->getAllocatedType()) * count + 3) / 4);
		std::string n = newt("A");
		decls.push_back(fmt("uint %s[%lld];", n.c_str(), (long long)words));
		auto m = std::make_shared<Mem>(); m->kind = "array"; m->name = n; m->words = words; m->writable = true;
		vals[&I] = GV::ptr(m, Off{}, a->getAllocatedType());
	} else if (auto *ci = dyn_cast<CallInst>(&I)) {
		call(*ci);
	} else if (auto *fr = dyn_cast<FreezeInst>(&I)) {
		define(I, ex(fr->getOperand(0)));
	} else {
		fail(std::string("instruction ") + I.getOpcodeName());
	}
}

void Translator::convert(CallInst &C, const std::string &name)
{
	SmallVector<StringRef, 8> parts;
	StringRef(name).split(parts, '.');
	std::string dk = parts.size() > 2 ? parts[2].str() : "", sk = parts.size() > 4 ? parts[4].str() : dk;
	Type *st = C.getArgOperand(0)->getType(), *t = C.getType();
	std::string x = ex(C.getArgOperand(0)), g = gty(t);
	Type *se = scal(st), *te = scal(t);
	if (dk == "f") {
		if (se->isIntegerTy()) {
			unsigned b = bitsOf(se);
			if (b == 1) { define(C, g + "(" + x + ")"); return; }
			if (sk == "u") { define(C, g + "(" + (isVec(st) ? fmt("uvec%u", vn(st)) : std::string("uint")) + "(" + zx(x, b) + "))"); return; }
			define(C, g + "(" + sx(x, b) + ")");
			return;
		}
		define(C, x);
		return;
	}
	if (te->isIntegerTy(1)) {
		define(C, isVec(st) ? "notEqual(" + x + ", " + gty(st) + "(0.0))" : "(" + x + " != 0.0)");
		return;
	}
	if (dk == "u") {
		std::string u = isVec(t) ? fmt("uvec%u", vn(t)) : "uint";
		define(C, wrap(g + "(" + u + "(max(" + x + ", " + gty(st) + "(0.0))))", bitsOf(te)));
		return;
	}
	define(C, g + "(" + x + ")");
}

std::string Translator::combined(const GV &tex, const GV *smp)
{
	if (tex.k != GV::Ptr || tex.mem->kind != "texture") fail("sample of non-texture");
	if (tex.mem->index == -1) fail("null texture sample");
	std::string skey;
	bool cs = false;
	int sid = -1;
	if (smp) {
		if (smp->k != GV::Ptr || smp->mem->kind != "sampler") fail("sampler operand");
		cs = smp->mem->constSampler >= 0;
		sid = cs ? smp->mem->constSampler : smp->mem->index;
		skey = fmt("%s%d", cs ? "c" : "s", sid);
	}
	std::string key = fmt("%d:", tex.mem->index) + skey;
	auto it = pairs.find(key);
	if (it != pairs.end()) return it->second;
	std::string n = fmt("TS%d_%s", tex.mem->index, smp ? skey.c_str() : "n");
	gout.push_back(fmt("uniform highp %s %s;", tex.mem->dim == "3d" ? "sampler3D" : "sampler2D", n.c_str()));
	pairs[key] = n;
	rPairs.push_back(fmt("{\"name\": %s, \"texture\": %d, \"sampler\": %s, \"const_sampler\": %s}", J::q(n).c_str(), tex.mem->index,
	    smp ? std::to_string(sid).c_str() : "null", cs ? "true" : "false"));
	return n;
}

std::string Translator::perTexture(const GV &tex, const std::function<std::string(const GV &)> &f, const std::string &null)
{
	auto one = [&](const GV &t) { return (t.k == GV::Ptr && t.mem->kind == "texture" && t.mem->index == -1) ? null : f(t); };
	if (tex.k == GV::Choice) {
		std::vector<std::string> e;
		for (auto &o : *tex.opts) e.push_back(one(o));
		return tex.pick(e);
	}
	return one(tex);
}

std::string Translator::sampleExpr(CallInst &C, const GV &tex, const GV &smp, const std::string &coord)
{
	if (tex.k == GV::Ptr && tex.mem->kind == "texture" && tex.mem->index == -1) return zero(C.getType());
	std::string ts = combined(tex, &smp);
	auto *lodc = dyn_cast<ConstantInt>(C.getArgOperand(5));
	bool lodExplicit = lodc && lodc->isOne();
	Value *bias = C.getArgOperand(6);
	auto *bc = dyn_cast<ConstantFP>(bias);
	std::string e;
	if (lodExplicit) e = "textureLod(" + ts + ", " + coord + ", " + ex(bias) + ")";
	else if (bc && bc->isZero()) e = "texture(" + ts + ", " + coord + ")";
	else e = "texture(" + ts + ", " + coord + ", " + ex(bias) + ")";
	return gty(C.getType()) + "(" + e + ", 0)";
}

void Translator::sample(CallInst &C)
{
	GV tex = val(C.getArgOperand(0)), smp = val(C.getArgOperand(1));
	std::string coord = ex(C.getArgOperand(2));
	if (tex.k == GV::Choice && smp.k == GV::Choice) {
		std::vector<std::string> outer;
		for (auto &t : *tex.opts) {
			std::vector<std::string> inner;
			for (auto &s : *smp.opts) inner.push_back(sampleExpr(C, t, s, coord));
			outer.push_back(smp.pick(inner));
		}
		define(C, tex.pick(outer));
		return;
	}
	if (tex.k == GV::Choice || smp.k == GV::Choice) {
		const GV &o = tex.k == GV::Choice ? tex : smp;
		std::vector<std::string> e;
		for (size_t k = 0; k < o.opts->size(); k++)
			e.push_back(sampleExpr(C, tex.k == GV::Choice ? (*tex.opts)[k] : tex, smp.k == GV::Choice ? (*smp.opts)[k] : smp, coord));
		define(C, o.pick(e));
		return;
	}
	define(C, sampleExpr(C, tex, smp, coord));
}

void Translator::call(CallInst &C)
{
	Function *callee = C.getCalledFunction();
	if (!callee) fail("indirect call");
	std::string name = callee->getName().str();
	if (name.rfind("air.", 0) != 0) fail("call " + name);
	/* air.[fast_]<fn>.<types> */
	std::string body = name.substr(4);
	if (body.rfind("fast_", 0) == 0) body = body.substr(5);
	std::string fn = body.substr(0, body.find('.'));
	auto X = [&](unsigned k) { return ex(C.getArgOperand(k)); };
	static const std::map<std::string, std::string> simple = {
		{"fabs", "abs"}, {"floor", "floor"}, {"ceil", "ceil"}, {"sqrt", "sqrt"}, {"rsqrt", "inversesqrt"},
		{"fract", "fract"}, {"sin", "sin"}, {"cos", "cos"}, {"exp", "exp"}, {"log", "log"}, {"log2", "log2"},
		{"exp2", "exp2"}, {"sign", "sign"}, {"trunc", "trunc"}, {"rint", "roundEven"}, {"round", "round"},
		{"dfdx", "dFdx"}, {"dfdy", "T290_DFDY"}, {"fwidth", "fwidth"}, {"normalize", "normalize"},
		{"length", "length"}, {"tan", "tan"}, {"atan", "atan"}, {"asin", "asin"}, {"acos", "acos"}};
	auto s = simple.find(fn);
	if (s != simple.end()) { define(C, s->second + "(" + X(0) + ")"); return; }
	if (name.rfind("air.min.u", 0) == 0 || name.rfind("air.max.u", 0) == 0) {
		define(C, std::string("int(") + (name[5] == 'i' ? "min" : "max") + "(uint(" + X(0) + "), uint(" + X(1) + ")))");
		return;
	}
	if (fn == "fmax" || fn == "fmin" || fn == "max" || fn == "min") {
		define(C, std::string(fn.find("max") != std::string::npos ? "max" : "min") + "(" + X(0) + ", " + X(1) + ")");
		return;
	}
	if (fn == "clamp") { define(C, "clamp(" + X(0) + ", " + X(1) + ", " + X(2) + ")"); return; }
	if (fn == "saturate") { define(C, "clamp(" + X(0) + ", 0.0, 1.0)"); return; }
	if (fn == "mix") { define(C, "mix(" + X(0) + ", " + X(1) + ", " + X(2) + ")"); return; }
	if (fn == "fma") { define(C, "(" + X(0) + " * " + X(1) + " + " + X(2) + ")"); return; }
	if (fn == "pow" || fn == "powr") { define(C, "pow(" + X(0) + ", " + X(1) + ")"); return; }
	if (fn == "atan2") { define(C, "atan(" + X(0) + ", " + X(1) + ")"); return; }
	if (fn == "dot") { define(C, "dot(" + X(0) + ", " + X(1) + ")"); return; }
	if (fn == "all" || fn == "any") { define(C, fn + "(" + X(0) + ")"); return; }
	if (name.rfind("air.convert.", 0) == 0) { convert(C, name); return; }
	if (name.rfind("air.unpack.unorm4x8", 0) == 0) { define(C, "unpackUnorm4x8(uint(" + X(0) + "))"); return; }
	if (name == "air.is_function_constant_defined") {
		GV p = val(C.getArgOperand(0));
		if (p.k != GV::Ptr || p.mem->kind != "fc") fail("constant query");
		usesFc.insert({p.mem->index, p.mem->code});
		define(C, fmt("(FCDEF%d != 0)", p.mem->index));
		return;
	}
	if (name.rfind("air.normalize_function_constant_predicate", 0) == 0) { define(C, "(" + X(0) + " != 0 ? 1 : 0)"); return; }
	if (name.rfind("air.sample_texture_", 0) == 0) { sample(C); return; }
	if (name.rfind("air.read_texture_2d", 0) == 0) {
		GV tex = val(C.getArgOperand(0));
		std::string g = gty(C.getType()), a1 = X(1), a2 = X(2);
		define(C, perTexture(tex, [&](const GV &t) { return g + "(texelFetch(" + combined(t, nullptr) + ", " + a1 + ", " + a2 + "), 0)"; }, zero(C.getType())));
		return;
	}
	if (name.rfind("air.get_width_texture", 0) == 0 || name.rfind("air.get_height_texture", 0) == 0) {
		GV tex = val(C.getArgOperand(0));
		std::string comp = name.find("width") != std::string::npos ? "x" : "y", a1 = X(1);
		define(C, perTexture(tex, [&](const GV &t) { return "textureSize(" + combined(t, nullptr) + ", " + a1 + ")." + comp; }, "0"));
		return;
	}
	if (name.rfind("air.get_null_texture", 0) == 0) {
		auto m = std::make_shared<Mem>(); m->kind = "texture"; m->name = "TNULL"; m->index = -1;
		vals[&C] = GV::ptr(m, Off{}, nullptr);
		return;
	}
	if (name.rfind("air.write_texture_2d", 0) == 0) {
		if (stage != "kernel" && stage != "fragment") fail("texture write in " + stage);
		GV tex = val(C.getArgOperand(0));
		if (tex.k != GV::Ptr) fail("texture write target");
		std::string img = fmt("IMG%d", tex.mem->index);
		bool seen = false;
		for (auto &g : gout) seen |= g.find(" " + img + ";") != std::string::npos;
		if (!seen) {
			gout.push_back("layout(rgba8) writeonly uniform highp image2D " + img + ";");
			rImages.push_back(fmt("{\"index\": %d}", tex.mem->index));
		}
		emit("imageStore(" + img + ", ivec2(" + X(1) + "), vec4(" + X(2) + "));");
		return;
	}
	if (name.rfind("air.wg.barrier", 0) == 0) { emit("barrier(); memoryBarrierShared();"); return; }
	fail("call " + name);
}

void Translator::assemble()
{
	std::vector<std::string> hdr = {"#version 310 es"};
	if (needTbuf) hdr.push_back("#extension GL_EXT_texture_buffer : require");
	hdr.push_back("precision highp float;");
	hdr.push_back("precision highp int;");
	if (needTbuf) hdr.push_back("precision highp usamplerBuffer;");
	hdr.push_back("#ifndef T290_SPECIALIZED");
	hdr.push_back("#error function constants not defined");
	hdr.push_back("#endif");
	if (needRtHeight)
		for (const char *l : {"uniform highp float T290_RT_HEIGHT;", "#ifndef T290_FRAG_Y",
		                      "#define T290_FRAG_Y(y) (T290_RT_HEIGHT - (y))", "#endif"})
			hdr.push_back(l);
	for (const char *l : {"#ifndef T290_DFDY", "#define T290_DFDY(x) dFdy(x)", "#endif"})     /* the driver flips y */
		hdr.push_back(l);
	if (stage == "kernel")
		hdr.push_back("layout(local_size_x = T290_LOCAL_X, local_size_y = T290_LOCAL_Y, local_size_z = T290_LOCAL_Z) in;");
	std::vector<std::string> sd;
	for (auto &s : structOrder) sd.push_back(sdecl(s.first, s.second));
	for (auto &u : uboSize) {
		int64_t n = std::max<int64_t>(u.second.first, u.second.second ? 1024 : 1);
		std::string tag = "@UBO_" + u.first + "@";
		for (auto &g : gout) {
			size_t p = g.find(tag);
			if (p != std::string::npos) g.replace(p, tag.size(), std::to_string(n));
		}
		std::string btag = "@UBOBYTES_" + u.first + "@";
		for (auto &b : rBuffers) {
			size_t p = b.find(btag);
			if (p != std::string::npos) b.replace(p, btag.size(), fmt(", \"ubo_bytes\": %lld", (long long)n * 16));
		}
	}
	for (auto &b : rBuffers) {      /* non-UBO buffers: drop the placeholder */
		size_t p = b.find("@UBOBYTES_");
		if (p != std::string::npos) b.erase(p, b.find('@', p + 1) - p + 1);
	}
	std::string o;
	for (auto &h : hdr) o += h + "\n";
	for (auto &s : sd) o += s + "\n";
	for (auto &g : gout) o += g + "\n";
	o += "void main() {\n";
	for (auto &d : decls) o += "    " + d + "\n";
	for (auto &l : initlines) o += l + "\n";
	for (auto &b : body) o += b + "\n";
	o += "}\n";
	glsl = o;

	std::vector<std::string> consts;
	for (auto &c : usesFc) consts.push_back(fmt("{\"index\": %d, \"type\": %s}", c.first, J::q(c.second).c_str()));
	std::vector<std::string> fb;
	for (int64_t x : fbInputs) fb.push_back(std::to_string(x));
	json = "{\n \"name\": " + J::q(F.getName().str()) + ",\n \"stage\": " + J::q(stage) +
	    ",\n \"inputs\": [" + join(rInputs) + "],\n \"outputs\": [" + join(rOutputs) +
	    "],\n \"buffers\": [" + join(rBuffers) + "],\n \"textures\": [" + join(rTextures) +
	    "],\n \"samplers\": [" + join(rSamplers) + "],\n \"pairs\": [" + join(rPairs) +
	    "],\n \"constants\": [" + join(consts) + "],\n \"const_samplers\": [" + join(rConstSamplers) +
	    "],\n \"fb_inputs\": [" + join(fb) + "],\n \"images\": [" + join(rImages) + "]\n}\n";
}

void Translator::run()
{
	/* entry metadata */
	const char *key = stage == "vertex" ? "air.vertex" : stage == "fragment" ? "air.fragment" : "air.kernel";
	NamedMDNode *nm = M.getNamedMetadata(key);
	std::vector<MI> outs, args;
	bool found = false;
	if (nm)
		for (MDNode *e : nm->operands()) {
			auto *fm = dyn_cast_or_null<ValueAsMetadata>(e->getOperand(0).get());
			if (!fm || fm->getValue()->stripPointerCasts() != &F) continue;
			if (e->getNumOperands() > 1) outs = flatten(e->getOperand(1).get()).l;
			if (e->getNumOperands() > 2) args = flatten(e->getOperand(2).get()).l;
			found = true;
		}
	if (!found) fail("no entry metadata");
	setupArgs(args);
	outMeta = outs;
	auto entryVals = vals;
	for (Function &f : M)
		if (!f.isDeclaration() && f.getSection() == "air.static_init") {
			prefix = "si_";
			emitBody(f);
		}
	prefix = "";
	for (auto &kv : entryVals) vals[kv.first] = kv.second;
	emitBody(F);
	assemble();
}

/* ---------------------------------------------------------------- specialization */

void specialize(Module &M, Function &entry, const airglc_constant *c, size_t n)
{
	std::map<uint32_t, const airglc_constant *> byIndex;
	for (size_t i = 0; i < n; i++) byIndex[c[i].index] = &c[i];
	std::map<GlobalVariable *, bool> defined;
	for (GlobalVariable &G : M.globals()) {
		if (G.getSection() != "air.fc_initializer") continue;
		int idx;
		std::string code;
		size_t p = G.getName().find("MTL_FC_INIT_");
		if (p == StringRef::npos) continue;
		idx = std::atoi(G.getName().substr(p + 12).str().c_str());
		auto it = byIndex.find((uint32_t)idx);
		Type *t = G.getValueType();
		auto scalar = [&](Type *st, double v) -> Constant * {
			if (st->isFloatingPointTy()) return ConstantFP::get(st, v);
			return ConstantInt::get(st, (uint64_t)(int64_t)v);
		};
		Constant *init;
		if (auto *vt = dyn_cast<FixedVectorType>(t)) {
			std::vector<Constant *> el;
			for (unsigned k = 0; k < vt->getNumElements(); k++)
				el.push_back(scalar(vt->getElementType(), it != byIndex.end() && k < it->second->count ? it->second->value[k] : 0));
			init = ConstantVector::get(el);
		} else {
			init = scalar(t, it != byIndex.end() ? it->second->value[0] : 0);
		}
		G.setInitializer(init);
		G.setConstant(true);
		G.setExternallyInitialized(false);
		G.setSection("");
		defined[&G] = it != byIndex.end();
	}
	std::vector<CallInst *> dead;
	for (Function &f : M) {
		if (!f.isDeclaration()) continue;
		StringRef nm = f.getName();
		bool isDef = nm == "air.is_function_constant_defined";
		bool isNorm = nm.startswith("air.normalize_function_constant_predicate");
		if (!isDef && !isNorm) continue;
		for (User *u : f.users())
			if (auto *ci = dyn_cast<CallInst>(u)) {
				if (isDef) {
					auto *g = dyn_cast<GlobalVariable>(ci->getArgOperand(0)->stripPointerCasts());
					ci->replaceAllUsesWith(ConstantInt::getBool(M.getContext(), g && defined[g]));
				} else {
					ci->replaceAllUsesWith(ci->getArgOperand(0));
				}
				dead.push_back(ci);
			}
	}
	for (CallInst *ci : dead) ci->eraseFromParent();
	/* static initializer runs inside the entry, so derived flags fold */
	for (Function &f : M)
		if (!f.isDeclaration() && f.getSection() == "air.static_init") {
			CallInst::Create(&f, "", &*entry.getEntryBlock().getFirstInsertionPt());
			f.setSection("");
		}
	if (GlobalVariable *ctors = M.getGlobalVariable("llvm.global_ctors")) ctors->eraseFromParent();
	for (Function &f : M)
		if (!f.isDeclaration() && &f != &entry) {
			f.removeFnAttr(Attribute::NoInline);
			f.addFnAttr(Attribute::AlwaysInline);
			f.setLinkage(GlobalValue::InternalLinkage);
		}
}

std::once_flag optionsOnce;

void optimize(Module &M)
{
	std::call_once(optionsOnce, [] {
		const char *argv[] = {"airglc", "-unroll-threshold=100000", "-inline-threshold=1000000"};
		cl::ParseCommandLineOptions(3, argv, "airglc\n");
	});
	PassBuilder PB;
	LoopAnalysisManager LAM;
	FunctionAnalysisManager FAM;
	CGSCCAnalysisManager CGAM;
	ModuleAnalysisManager MAM;
	PB.registerModuleAnalyses(MAM);
	PB.registerCGSCCAnalyses(CGAM);
	PB.registerFunctionAnalyses(FAM);
	PB.registerLoopAnalyses(LAM);
	PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
	std::string fold = "function(sroa,instcombine,sccp,gvn,instcombine,simplifycfg,adce)";
	std::string loops = "function(loop-simplify,lcssa,loop-rotate,loop-unroll-full,loop-unroll<O3>,sroa,instcombine,"
	                    "sccp,gvn,instcombine,simplifycfg,adce)";
	std::string pipeline = "always-inline," + fold + ",globalopt," + fold + ",globalopt," + loops + "," + fold + ",globaldce";
	ModulePassManager MPM;
	if (Error e = PB.parsePassPipeline(MPM, pipeline)) fail("pass pipeline: " + toString(std::move(e)));
	MPM.run(M, MAM);
}

char *dup(const std::string &s)
{
	char *p = (char *)malloc(s.size() + 1);
	memcpy(p, s.c_str(), s.size() + 1);
	return p;
}

} /* namespace */

extern "C" int airglc_compile(const void *bitcode, size_t size, const char *function,
                              const airglc_constant *constants, size_t count,
                              char **glsl, char **json, char **error)
{
	*glsl = *json = *error = nullptr;
	LLVMContext ctx;
	auto buf = MemoryBuffer::getMemBuffer(StringRef((const char *)bitcode, size), "air", false);
	Expected<std::unique_ptr<Module>> mod = parseBitcodeFile(buf->getMemBufferRef(), ctx);
	if (!mod) {
		*error = dup("bitcode: " + toString(mod.takeError()));
		return 1;
	}
	Module &M = **mod;
	M.setTargetTriple("");
	Function *F = function ? M.getFunction(function) : nullptr;
	if (!F || F->isDeclaration()) {
		*error = dup(std::string("no function ") + (function ? function : "(null)"));
		return 2;
	}
	std::string stage;
	for (const char *k : {"air.vertex", "air.fragment", "air.kernel"})
		if (NamedMDNode *nm = M.getNamedMetadata(k))
			for (MDNode *e : nm->operands())
				if (auto *v = dyn_cast_or_null<ValueAsMetadata>(e->getOperand(0).get()))
					if (v->getValue()->stripPointerCasts() == F) stage = std::string(k).substr(4);
	if (stage.empty()) {
		*error = dup("no stage metadata for " + std::string(function));
		return 3;
	}
	try {
		specialize(M, *F, constants, count);
		optimize(M);
		Translator t(M, *F, stage);
		t.run();
		*glsl = dup(t.glsl);
		*json = dup(t.json);
		return 0;
	} catch (const Unsupported &u) {
		*error = dup(u.what);
		return 4;
	}
}

extern "C" int airglc_constants(const void *bitcode, size_t size, char **json, char **error)
{
	*json = *error = nullptr;
	LLVMContext ctx;
	auto buf = MemoryBuffer::getMemBuffer(StringRef((const char *)bitcode, size), "air", false);
	Expected<std::unique_ptr<Module>> mod = parseBitcodeFile(buf->getMemBufferRef(), ctx);
	if (!mod) {
		*error = dup("bitcode: " + toString(mod.takeError()));
		return 1;
	}
	std::vector<std::string> items;
	for (GlobalVariable &G : (*mod)->globals()) {
		if (G.getSection() != "air.fc_initializer") continue;
		StringRef n = G.getName();
		size_t p = n.find(".MTL_FC_INIT_");
		if (p == StringRef::npos) continue;
		StringRef rest = n.substr(p + 13);
		size_t u = rest.find('_');
		if (u == StringRef::npos) continue;
		/* "_Z<len><name>" (mangled C++ name) or a plain name */
		std::string name = n.substr(0, p).str();
		if (name.rfind("_Z", 0) == 0) {
			size_t k = 2;
			while (k < name.size() && isdigit((unsigned char)name[k])) k++;
			name = name.substr(k);
		}
		items.push_back(fmt("{\"index\": %d, \"name\": %s, \"type\": %s}", std::atoi(rest.substr(0, u).str().c_str()),
		    J::q(name).c_str(), J::q(rest.substr(u + 1).str()).c_str()));
	}
	*json = dup("[" + join(items) + "]");
	return 0;
}

extern "C" void airglc_free(void *p) { free(p); }
