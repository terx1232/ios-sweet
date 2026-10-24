/* T290Metal shaders: metallib parsing, functions with constants, AIR -> GLSL
 * (airglc), GL program linking with explicit bindings, pipeline states. */
#import "t290mtl.h"
#include "../compiler/airglc.h"
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

/* ------------------------------------------------------------------ metallib */

/* MTLB container: header, then (offset, size) pairs at 0x18: function list,
 * public metadata, private metadata, bitcode. Function entries are tag lists
 * (NAME, TYPE, OFFT = 3 x u64 offsets with the bitcode offset last, MDSZ =
 * bitcode size, ..., ENDT). */
static NSDictionary *parse_metallib(NSData *data, NSString **err)
{
	const uint8_t *d = data.bytes;
	size_t n = data.length;
	if (n < 0x58 || memcmp(d, "MTLB", 4)) { *err = @"not a metallib"; return nil; }
	uint64_t sec[8];
	memcpy(sec, d + 0x18, sizeof(sec));
	uint64_t fo = sec[0], fs = sec[1], bo = sec[6], bs = sec[7];
	if (fo + fs > n || bo + bs > n || fs < 4) { *err = @"metallib sections out of range"; return nil; }
	uint32_t count;
	memcpy(&count, d + fo, 4);
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	size_t p = fo + 4;
	for (uint32_t i = 0; i < count; i++) {
		if (p + 4 > fo + fs) { *err = @"function list truncated"; return nil; }
		uint32_t size;
		memcpy(&size, d + p, 4);
		size_t q = p + 4, e = p + size;
		NSString *name = nil;
		int type = -1;
		uint64_t off = UINT64_MAX, len = 0;
		while (q + 4 <= e) {
			if (!memcmp(d + q, "ENDT", 4)) break;
			uint16_t l;
			memcpy(&l, d + q + 4, 2);
			const uint8_t *v = d + q + 6;
			if (!memcmp(d + q, "NAME", 4)) name = [[NSString alloc] initWithBytes:v length:strnlen((const char *)v, l) encoding:NSUTF8StringEncoding];
			else if (!memcmp(d + q, "TYPE", 4) && l >= 1) type = v[0];
			else if (!memcmp(d + q, "OFFT", 4) && l >= 24) memcpy(&off, v + 16, 8);
			else if (!memcmp(d + q, "MDSZ", 4) && l >= 8) memcpy(&len, v, 8);
			q += 6 + l;
		}
		p = e;
		if (!name || off == UINT64_MAX || off + len > bs) continue;
		out[name] = @{@"type": @(type), @"data": [data subdataWithRange:NSMakeRange(bo + off, len)]};
	}
	return out;
}

/* ------------------------------------------------------------------ functions */

@interface T290FunctionConstant : NSObject
@property (copy) NSString *name;
@property MTLDataType type;
@property NSUInteger index;
@property BOOL required;
@end
@implementation T290FunctionConstant
@end

static MTLDataType constant_type(NSString *code)
{
	if ([code isEqual:@"b"]) return MTLDataTypeBool;
	if ([code isEqual:@"h"]) return MTLDataTypeUChar;
	if ([code isEqual:@"c"] || [code isEqual:@"a"]) return MTLDataTypeChar;
	if ([code isEqual:@"t"]) return MTLDataTypeUShort;
	if ([code isEqual:@"s"]) return MTLDataTypeShort;
	if ([code isEqual:@"j"]) return MTLDataTypeUInt;
	if ([code isEqual:@"i"]) return MTLDataTypeInt;
	if ([code isEqual:@"f"]) return MTLDataTypeFloat;
	if ([code isEqual:@"Dh"]) return MTLDataTypeHalf;
	if ([code hasPrefix:@"Dv"] && code.length >= 5) {
		MTLDataType base = constant_type([code substringFromIndex:4]);
		int n = [code characterAtIndex:2] - '0';
		if (n >= 2 && n <= 4 && base != MTLDataTypeNone) return base + (NSUInteger)n - 1;
	}
	return MTLDataTypeNone;
}

@implementation T290Function
- (NSString *)name { return _name; }
- (MTLFunctionType)functionType { return _type; }
- (MTLPatchType)patchType { return MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount { return -1; }
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes { return @[]; }
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
- (NSArray *)constants
{
	if (!_constants) {
		char *json = NULL, *err = NULL;
		if (airglc_constants(_bitcode.bytes, _bitcode.length, &json, &err) == 0)
			_constants = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
		else
			t290_log("T290Metal: constants of %s: %s", _name.UTF8String, err);
		airglc_free(json);
		airglc_free(err);
		if (!_constants) _constants = @[];
	}
	return _constants;
}
- (NSDictionary<NSString *, MTLFunctionConstant *> *)functionConstantsDictionary
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	for (NSDictionary *c in self.constants) {
		T290FunctionConstant *k = [T290FunctionConstant new];
		k.name = c[@"name"];
		k.index = [c[@"index"] unsignedIntegerValue];
		k.type = constant_type(c[@"type"]);
		k.required = NO;
		d[k.name] = k;
	}
	return (NSDictionary *)d;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)i { (void)i; return nil; }
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)i reflection:(MTLAutoreleasedArgument *)r
{
	(void)i; (void)r;
	return nil;
}
- (T290Function *)specialized:(MTLFunctionConstantValues *)values
{
	T290Function *f = [[T290Function alloc] initWithDevice:(T290Device *)self.device];
	f->_bitcode = _bitcode;
	f->_name = _name;
	f->_type = _type;
	f->_constants = self.constants;
	f->_library = _library;
	NSMutableDictionary *byIndex = [NSMutableDictionary dictionary];
	NSDictionary *set = t290_constant_values(values);
	for (id key in set) {
		if ([key isKindOfClass:[NSNumber class]]) { byIndex[key] = set[key]; continue; }
		for (NSDictionary *c in f->_constants)
			if ([c[@"name"] isEqual:key]) byIndex[c[@"index"]] = set[key];
	}
	f->_values = byIndex;
	return f;
}
@end

/* ------------------------------------------------------------------ library */

@implementation T290Library {
	NSDictionary *_functions;
}
- (instancetype)initWithDevice:(T290Device *)device data:(NSData *)data error:(NSError **)error
{
	if (!(self = [super initWithDevice:device])) return nil;
	NSString *why = nil;
	_functions = parse_metallib(data, &why);
	if (!_functions) {
		if (error) *error = t290_error(@"metallib: %@", why);
		return nil;
	}
	t290_log("T290Metal: library with %lu functions", (unsigned long)_functions.count);
	return self;
}
- (NSArray<NSString *> *)functionNames { return _functions.allKeys; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return nil; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	NSDictionary *e = _functions[name];
	if (!e) { t290_log("T290Metal: no function %s", name.UTF8String); return nil; }
	T290Function *f = [[T290Function alloc] initWithDevice:(T290Device *)self.device];
	f->_bitcode = e[@"data"];
	f->_name = [name copy];
	int t = [e[@"type"] intValue];
	f->_type = t == 0 ? MTLFunctionTypeVertex : t == 1 ? MTLFunctionTypeFragment : MTLFunctionTypeKernel;
	f->_library = self;
	f->_values = @{};
	return f;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error
{
	T290Function *f = (T290Function *)[self newFunctionWithName:name];
	if (!f) {
		if (error) *error = t290_error(@"no function %@", name);
		return nil;
	}
	return [f specialized:values];
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values
          completionHandler:(void (^)(id<MTLFunction>, NSError *))handler
{
	NSError *e = nil;
	id<MTLFunction> f = [self newFunctionWithName:name constantValues:values error:&e];
	handler(f, e);
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error
{
	return [self newFunctionWithName:d.name constantValues:d.constantValues error:error];
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d completionHandler:(void (^)(id<MTLFunction>, NSError *))handler
{
	NSError *e = nil;
	id<MTLFunction> f = [self newFunctionWithDescriptor:d error:&e];
	handler(f, e);
}
@end

/* ------------------------------------------------------------------ compiling */

static pthread_mutex_t compile_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *shader_cache;

/* Translations persist across processes and boots (fixed_frag takes ~3.5 s
 * on the tablet). Key: SHA-256 of the bitcode, function, constants and the
 * translator revision; one file per shader: GLSL, a marker line, JSON. */
#define T290_CACHE_DIR "/private/var/tmp/t290metal-cache"
#define T290_CACHE_REV "airglc-1"
static NSString *const cache_sep = @"\n//T290-REFLECTION\n";

static NSString *cache_path(T290Function *f, NSString *constants)
{
	CC_SHA256_CTX c;
	unsigned char md[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256_Init(&c);
	CC_SHA256_Update(&c, f->_bitcode.bytes, (CC_LONG)f->_bitcode.length);
	NSData *rest = [[NSString stringWithFormat:@"|%@|%@|%s", f->_name, constants, T290_CACHE_REV] dataUsingEncoding:NSUTF8StringEncoding];
	CC_SHA256_Update(&c, rest.bytes, (CC_LONG)rest.length);
	CC_SHA256_Final(md, &c);
	NSMutableString *hex = [NSMutableString stringWithString:@T290_CACHE_DIR "/"];
	for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", md[i]];
	[hex appendString:@".glsl"];
	return hex;
}

static T290Shader *cache_load(NSString *path)
{
	NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	NSRange r = s ? [s rangeOfString:cache_sep options:NSBackwardsSearch] : NSMakeRange(NSNotFound, 0);
	if (r.location == NSNotFound) return nil;
	T290Shader *sh = [T290Shader new];
	sh->glsl = [s substringToIndex:r.location];
	NSData *j = [[s substringFromIndex:NSMaxRange(r)] dataUsingEncoding:NSUTF8StringEncoding];
	sh->refl = [NSJSONSerialization JSONObjectWithData:j options:0 error:nil];
	return sh->refl ? sh : nil;
}

static void cache_store(NSString *path, NSString *glsl, const char *json)
{
	mkdir(T290_CACHE_DIR, 01777);
	chmod(T290_CACHE_DIR, 01777);
	NSString *tmp = [path stringByAppendingFormat:@".%d", getpid()];
	NSString *s = [NSString stringWithFormat:@"%@%@%s", glsl, cache_sep, json];
	if ([s writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
		chmod(tmp.fileSystemRepresentation, 0644);
		rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
	}
}

@implementation T290Shader
+ (T290Shader *)compile:(T290Function *)f error:(NSError **)error
{
	NSArray *keys = [f->_values.allKeys sortedArrayUsingSelector:@selector(compare:)];
	NSMutableString *consts = [NSMutableString string];
	for (NSNumber *k in keys) [consts appendFormat:@" %@=%@", k, [f->_values[k] componentsJoinedByString:@","]];
	NSString *key = [NSString stringWithFormat:@"%p/%@%@", f->_bitcode.bytes, f->_name, consts];
	pthread_mutex_lock(&compile_lock);
	if (!shader_cache) shader_cache = [NSMutableDictionary dictionary];
	T290Shader *s = shader_cache[key];
	if (s) { pthread_mutex_unlock(&compile_lock); return s; }
	NSString *disk = cache_path(f, consts);
	if ((s = cache_load(disk))) {
		shader_cache[key] = s;
		pthread_mutex_unlock(&compile_lock);
		return s;
	}
	struct airglc_constant *c = calloc(keys.count ?: 1, sizeof(*c));
	size_t n = 0;
	for (NSNumber *k in keys) {
		NSArray *v = f->_values[k];
		c[n].index = k.unsignedIntValue;
		c[n].count = (uint32_t)MIN(v.count, 4u);
		for (uint32_t i = 0; i < c[n].count; i++) c[n].value[i] = [v[i] doubleValue];
		n++;
	}
	char *glsl = NULL, *json = NULL, *err = NULL;
	CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
	int rc = airglc_compile(f->_bitcode.bytes, f->_bitcode.length, f->_name.UTF8String, c, n, &glsl, &json, &err);
	double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
	free(c);
	if (rc) {
		pthread_mutex_unlock(&compile_lock);
		if (error) *error = t290_error(@"%@: %s", f->_name, err ?: "?");
		airglc_free(err);
		return nil;
	}
	s = [T290Shader new];
	s->glsl = [NSString stringWithUTF8String:glsl];
	s->refl = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
	cache_store(disk, s->glsl, json);
	airglc_free(glsl);
	airglc_free(json);
	shader_cache[key] = s;
	pthread_mutex_unlock(&compile_lock);
	t290_log("T290Metal: compiled %s (%lu constants) in %.0f ms, %lu bytes GLSL", f->_name.UTF8String,
	    (unsigned long)n, ms, (unsigned long)s->glsl.length);
	return s;
}
@end

/* ------------------------------------------------------------------ programs */

static NSString *replace_once(NSString *text, NSString *old, NSString *new)
{
	NSRange r = [text rangeOfString:old];
	if (r.location == NSNotFound) { t290_log("T290Metal: GLSL edit missed: %s", old.UTF8String); return text; }
	return [text stringByReplacingCharactersInRange:r withString:new];
}

static GLuint compile_shader(GLenum type, NSString *text, NSError **error)
{
	GLuint s = gl.CreateShader(type);
	const char *src = text.UTF8String;
	gl.ShaderSource(s, 1, &src, NULL);
	gl.CompileShader(s);
	GLint ok = 0;
	gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048] = {0};
		gl.GetShaderInfoLog(s, sizeof(log) - 1, NULL, log);
		*error = t290_error(@"shader compile: %s", log);
		NSArray *lines = [text componentsSeparatedByString:@"\n"];
		for (NSUInteger i = 0; i < lines.count && i < 60; i++) t290_log("  %3lu %s", (unsigned long)i + 1, [lines[i] UTF8String]);
		gl.DeleteShader(s);
		return 0;
	}
	return s;
}

static GLuint const_sampler(uint64_t state)
{
	/* AIR constexpr sampler bits are not decoded yet: linear, clamp to edge. */
	static unsigned logged;
	if (logged++ < 8) t290_log("T290Metal: const sampler state %#llx (decoded as linear/clamp)", (unsigned long long)state);
	GLuint o;
	gl.GenSamplers(1, &o);
	gl.SamplerParameteri(o, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	gl.SamplerParameteri(o, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	gl.SamplerParameteri(o, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	gl.SamplerParameteri(o, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	gl.SamplerParameteri(o, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
	return o;
}

@interface T290Program ()
- (BOOL)link:(NSArray<T290Shader *> *)shaders error:(NSError **)error;
@end

@implementation T290Program
- (BOOL)linkStages:(NSArray<T290Shader *> *)shaders error:(NSError **)error
{
	__block BOOL ok = NO;
	__block NSError *e = nil;
	t290_gl_sync(^{
		NSError *le = nil;
		ok = [self link:shaders error:&le];
		e = le;
	});
	if (!ok && error) *error = e;
	return ok;
}

- (BOOL)link:(NSArray<T290Shader *> *)shaders error:(NSError **)error
{
	GLuint ubo = 0, ssbo = 0, unit = 0, image = 0;
	NSMutableArray *objects = [NSMutableArray array];
	NSMutableSet *flats = [NSMutableSet set];
	for (T290Shader *s in shaders)
		if ([s->refl[@"stage"] isEqual:@"fragment"])
			for (NSDictionary *in in s->refl[@"inputs"])
				if ([in[@"interp"] isEqual:@"flat"]) [flats addObject:in[@"key"]];
	for (T290Shader *s in shaders) {
		NSString *stageName = s->refl[@"stage"];
		uint8_t stage = [stageName isEqual:@"vertex"] ? T290_STAGE_VERTEX : [stageName isEqual:@"fragment"] ? T290_STAGE_FRAGMENT : T290_STAGE_COMPUTE;
		NSString *text = s->glsl;
		NSString *p = @"";
		if (stage == T290_STAGE_VERTEX) {
			/* uniform names are program-wide: give the vertex stage its own */
			p = @"V";
			NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
			    @"\\b(B\\d+_[UTS](?:_blk)?|TS\\d+_\\w+|IMG\\d+)\\b" options:0 error:nil];
			text = [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"V$1"];
		}
		NSMutableString *defs = [NSMutableString stringWithString:
		    @"#define T290_SPECIALIZED 1\n#define T290_FRAG_Y(y) (y)\n#define T290_DFDY(x) (-dFdy(x))\n"];
		if (stage == T290_STAGE_VERTEX)
			for (NSString *k in flats) [defs appendFormat:@"#define T290_Q_%@ flat\n", k];
		for (NSDictionary *b in s->refl[@"buffers"]) {
			if (_nbind >= sizeof(_bind) / sizeof(_bind[0])) break;
			NSString *kind = b[@"kind"], *name = [p stringByAppendingString:b[@"name"]];
			struct t290_binding *x = &_bind[_nbind++];
			x->stage = stage;
			x->index = [b[@"index"] unsignedCharValue];
			if ([kind isEqual:@"ubo"]) {
				x->kind = T290_BIND_UBO; x->slot = ubo++;
				x->bytes = [b[@"ubo_bytes"] integerValue];
				text = replace_once(text, [NSString stringWithFormat:@"layout(std140) uniform %@_blk", name],
				    [NSString stringWithFormat:@"layout(std140, binding = %u) uniform %@_blk", x->slot, name]);
			} else if ([kind isEqual:@"ssbo"]) {
				x->kind = T290_BIND_SSBO; x->slot = ssbo++;
				text = replace_once(text, [NSString stringWithFormat:@"layout(std430) buffer %@_blk", name],
				    [NSString stringWithFormat:@"layout(std430, binding = %u) buffer %@_blk", x->slot, name]);
			} else {
				x->kind = T290_BIND_TBO; x->slot = unit++;
				text = replace_once(text, [NSString stringWithFormat:@"uniform highp usamplerBuffer %@;", name],
				    [NSString stringWithFormat:@"layout(binding = %u) uniform highp usamplerBuffer %@;", x->slot, name]);
			}
		}
		NSMutableDictionary *constIds = [NSMutableDictionary dictionary];
		for (NSDictionary *cs in s->refl[@"const_samplers"]) {
			if (_nconstSamplers >= 16) break;
			_constSamplers[_nconstSamplers] = const_sampler([cs[@"state"] unsignedLongLongValue]);
			constIds[cs[@"id"]] = @(_nconstSamplers++);
		}
		for (NSDictionary *pr in s->refl[@"pairs"]) {
			if (_npairs >= sizeof(_pairs) / sizeof(_pairs[0])) break;
			struct t290_pair *x = &_pairs[_npairs++];
			x->stage = stage;
			x->texture = [pr[@"texture"] unsignedCharValue];
			id smp = pr[@"sampler"];
			if (smp == [NSNull null]) x->sampler = INT16_MAX;
			else if ([pr[@"const_sampler"] boolValue]) x->sampler = (int16_t)(-1 - [constIds[smp] intValue]);
			else x->sampler = [smp shortValue];
			x->unit = unit++;
			NSString *name = [p stringByAppendingString:pr[@"name"]];
			NSString *type = [text containsString:[NSString stringWithFormat:@"sampler3D %@;", name]] ? @"sampler3D" : @"sampler2D";
			x->is3D = [type isEqual:@"sampler3D"];
			text = replace_once(text, [NSString stringWithFormat:@"uniform highp %@ %@;", type, name],
			    [NSString stringWithFormat:@"layout(binding = %u) uniform highp %@ %@;", x->unit, type, name]);
		}
		for (NSNumber *rt in s->refl[@"fb_inputs"]) {
			if (_nfb >= 8) break;
			_fbInput[_nfb] = rt.charValue;
			_fbUnit[_nfb] = unit++;
			text = replace_once(text, [NSString stringWithFormat:@"uniform highp sampler2D T290_FB%@;", rt],
			    [NSString stringWithFormat:@"layout(binding = %u) uniform highp sampler2D T290_FB%@;", _fbUnit[_nfb], rt]);
			_nfb++;
		}
		for (NSDictionary *im in s->refl[@"images"]) {
			if (_nimages >= 8) break;
			_images[_nimages++] = [im[@"index"] unsignedIntValue];
			NSString *name = [NSString stringWithFormat:@"%@IMG%@", p, im[@"index"]];
			text = replace_once(text, [NSString stringWithFormat:@"layout(rgba8) writeonly uniform highp image2D %@;", name],
			    [NSString stringWithFormat:@"layout(rgba8, binding = %u) writeonly uniform highp image2D %@;", image++, name]);
		}
		/* defines go after #version and #extension */
		NSMutableArray *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
		NSUInteger k = 1;
		while (k < lines.count && [lines[k] hasPrefix:@"#extension"]) k++;
		[lines insertObject:defs atIndex:k];
		text = [lines componentsJoinedByString:@"\n"];
		GLenum type = stage == T290_STAGE_VERTEX ? GL_VERTEX_SHADER : stage == T290_STAGE_FRAGMENT ? GL_FRAGMENT_SHADER : GL_COMPUTE_SHADER;
		GLuint sh = compile_shader(type, text, error);
		if (!sh) {
			for (NSNumber *o in objects) gl.DeleteShader(o.unsignedIntValue);
			return NO;
		}
		[objects addObject:@(sh)];
	}
	if (shaders.count == 1 && [shaders[0]->refl[@"stage"] isEqual:@"vertex"]) {
		/* rasterization without a fragment function */
		NSString *empty = @"#version 310 es\nvoid main() {}\n";
		GLuint sh = compile_shader(GL_FRAGMENT_SHADER, empty, error);
		if (sh) [objects addObject:@(sh)];
	}
	_program = gl.CreateProgram();
	for (NSNumber *o in objects) gl.AttachShader(_program, o.unsignedIntValue);
	gl.LinkProgram(_program);
	for (NSNumber *o in objects) gl.DeleteShader(o.unsignedIntValue);
	GLint ok = 0;
	gl.GetProgramiv(_program, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[2048] = {0};
		gl.GetProgramInfoLog(_program, sizeof(log) - 1, NULL, log);
		*error = t290_error(@"program link: %s", log);
		gl.DeleteProgram(_program);
		_program = 0;
		return NO;
	}
	_rtHeight = gl.GetUniformLocation(_program, "T290_RT_HEIGHT");
	return YES;
}

- (void)dealloc
{
	GLuint p = _program;
	unsigned n = _nconstSamplers;
	struct { GLuint s[16]; } cs;
	memcpy(cs.s, _constSamplers, sizeof(cs.s));
	t290_gl_async(^{
		if (p) gl.DeleteProgram(p);
		if (n) gl.DeleteSamplers((GLsizei)n, cs.s);
	});
}
@end

/* ------------------------------------------------------------------ render pipelines */

static BOOL vertex_format(MTLVertexFormat f, GLint *size, GLenum *type, GLboolean *norm, GLboolean *integer)
{
	*norm = GL_FALSE;
	*integer = GL_FALSE;
	switch (f) {
	case MTLVertexFormatUChar2: case MTLVertexFormatUChar3: case MTLVertexFormatUChar4:
		*size = (GLint)(f - MTLVertexFormatUChar2) + 2; *type = GL_UNSIGNED_BYTE; *integer = GL_TRUE; return YES;
	case MTLVertexFormatChar2: case MTLVertexFormatChar3: case MTLVertexFormatChar4:
		*size = (GLint)(f - MTLVertexFormatChar2) + 2; *type = GL_BYTE; *integer = GL_TRUE; return YES;
	case MTLVertexFormatUChar2Normalized: case MTLVertexFormatUChar3Normalized: case MTLVertexFormatUChar4Normalized:
		*size = (GLint)(f - MTLVertexFormatUChar2Normalized) + 2; *type = GL_UNSIGNED_BYTE; *norm = GL_TRUE; return YES;
	case MTLVertexFormatChar2Normalized: case MTLVertexFormatChar3Normalized: case MTLVertexFormatChar4Normalized:
		*size = (GLint)(f - MTLVertexFormatChar2Normalized) + 2; *type = GL_BYTE; *norm = GL_TRUE; return YES;
	case MTLVertexFormatUShort2: case MTLVertexFormatUShort3: case MTLVertexFormatUShort4:
		*size = (GLint)(f - MTLVertexFormatUShort2) + 2; *type = GL_UNSIGNED_SHORT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatShort2: case MTLVertexFormatShort3: case MTLVertexFormatShort4:
		*size = (GLint)(f - MTLVertexFormatShort2) + 2; *type = GL_SHORT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatUShort2Normalized: case MTLVertexFormatUShort3Normalized: case MTLVertexFormatUShort4Normalized:
		*size = (GLint)(f - MTLVertexFormatUShort2Normalized) + 2; *type = GL_UNSIGNED_SHORT; *norm = GL_TRUE; return YES;
	case MTLVertexFormatShort2Normalized: case MTLVertexFormatShort3Normalized: case MTLVertexFormatShort4Normalized:
		*size = (GLint)(f - MTLVertexFormatShort2Normalized) + 2; *type = GL_SHORT; *norm = GL_TRUE; return YES;
	case MTLVertexFormatHalf2: case MTLVertexFormatHalf3: case MTLVertexFormatHalf4:
		*size = (GLint)(f - MTLVertexFormatHalf2) + 2; *type = GL_HALF_FLOAT; return YES;
	case MTLVertexFormatFloat: case MTLVertexFormatFloat2: case MTLVertexFormatFloat3: case MTLVertexFormatFloat4:
		*size = (GLint)(f - MTLVertexFormatFloat) + 1; *type = GL_FLOAT; return YES;
	case MTLVertexFormatInt: case MTLVertexFormatInt2: case MTLVertexFormatInt3: case MTLVertexFormatInt4:
		*size = (GLint)(f - MTLVertexFormatInt) + 1; *type = GL_INT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatUInt: case MTLVertexFormatUInt2: case MTLVertexFormatUInt3: case MTLVertexFormatUInt4:
		*size = (GLint)(f - MTLVertexFormatUInt) + 1; *type = GL_UNSIGNED_INT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatInt1010102Normalized: *size = 4; *type = GL_INT_2_10_10_10_REV; *norm = GL_TRUE; return YES;
	case MTLVertexFormatUInt1010102Normalized: *size = 4; *type = GL_UNSIGNED_INT_2_10_10_10_REV; *norm = GL_TRUE; return YES;
	case MTLVertexFormatUChar: *size = 1; *type = GL_UNSIGNED_BYTE; *integer = GL_TRUE; return YES;
	case MTLVertexFormatChar: *size = 1; *type = GL_BYTE; *integer = GL_TRUE; return YES;
	case MTLVertexFormatUCharNormalized: *size = 1; *type = GL_UNSIGNED_BYTE; *norm = GL_TRUE; return YES;
	case MTLVertexFormatCharNormalized: *size = 1; *type = GL_BYTE; *norm = GL_TRUE; return YES;
	case MTLVertexFormatUShort: *size = 1; *type = GL_UNSIGNED_SHORT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatShort: *size = 1; *type = GL_SHORT; *integer = GL_TRUE; return YES;
	case MTLVertexFormatUShortNormalized: *size = 1; *type = GL_UNSIGNED_SHORT; *norm = GL_TRUE; return YES;
	case MTLVertexFormatShortNormalized: *size = 1; *type = GL_SHORT; *norm = GL_TRUE; return YES;
	case MTLVertexFormatHalf: *size = 1; *type = GL_HALF_FLOAT; return YES;
	default: return NO;     /* UChar4Normalized_BGRA needs a swizzle */
	}
}

static GLenum blend_factor(MTLBlendFactor f)
{
	static const GLenum t[] = {GL_ZERO, GL_ONE, GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
		GL_DST_COLOR, GL_ONE_MINUS_DST_COLOR, GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA, GL_SRC_ALPHA_SATURATE,
		GL_CONSTANT_COLOR, GL_ONE_MINUS_CONSTANT_COLOR, GL_CONSTANT_ALPHA, GL_ONE_MINUS_CONSTANT_ALPHA};
	if (f < sizeof(t) / sizeof(t[0])) return t[f];
	t290_log("T290Metal: dual-source blend factor %lu unsupported", (unsigned long)f);
	return GL_ONE;
}

static GLenum blend_op(MTLBlendOperation o)
{
	static const GLenum t[] = {GL_FUNC_ADD, GL_FUNC_SUBTRACT, GL_FUNC_REVERSE_SUBTRACT, GL_MIN, GL_MAX};
	return o < 5 ? t[o] : GL_FUNC_ADD;
}

@implementation T290RenderPipeline
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
	if (!(self = [super initWithDevice:device])) return nil;
	self.label = d.label;
	T290Function *vf = (T290Function *)d.vertexFunction, *ff = (T290Function *)d.fragmentFunction;
	if (![vf isKindOfClass:[T290Function class]] || (ff && ![ff isKindOfClass:[T290Function class]])) {
		if (error) *error = t290_error(@"pipeline functions are not T290Metal functions");
		return nil;
	}
	NSError *e = nil;
	T290Shader *vs = [T290Shader compile:vf error:&e];
	T290Shader *fs = ff && d.rasterizationEnabled ? [T290Shader compile:ff error:&e] : nil;
	if (!vs || (ff && d.rasterizationEnabled && !fs)) {
		if (error) *error = e;
		return nil;
	}
	_prog = [T290Program new];
	if (![_prog linkStages:fs ? @[vs, fs] : @[vs] error:error]) {
		t290_log("T290Metal: pipeline %s + %s failed", vf->_name.UTF8String, ff ? ff->_name.UTF8String : "-");
		return nil;
	}
	MTLVertexDescriptor *vd = d.vertexDescriptor;
	for (NSDictionary *in in vs->refl[@"inputs"]) {
		NSUInteger loc = [in[@"location"] unsignedIntegerValue];
		MTLVertexAttributeDescriptor *a = vd.attributes[loc];
		if (!vd || a.format == MTLVertexFormatInvalid) {
			t290_log("T290Metal: %s input %lu has no vertex descriptor attribute", vf->_name.UTF8String, (unsigned long)loc);
			continue;
		}
		struct t290_attrib *x = &_attribs[_nattribs];
		if (_nattribs >= 16 || !vertex_format(a.format, &x->size, &x->type, &x->normalized, &x->integer)) {
			t290_log("T290Metal: vertex format %lu unsupported", (unsigned long)a.format);
			continue;
		}
		NSString *t = in[@"type"];
		if (![t hasPrefix:@"int"] && ![t hasPrefix:@"ivec"]) x->integer = GL_FALSE;     /* converted to float */
		x->location = (GLuint)loc;
		x->buffer = (uint8_t)a.bufferIndex;
		x->offset = (GLuint)a.offset;
		_nattribs++;
		_hasVertexDescriptor = YES;
	}
	for (NSUInteger i = 0; vd && i < T290_MAX_BUFFERS; i++) {
		MTLVertexBufferLayoutDescriptor *l = vd.layouts[i];
		_layouts[i].stride = l.stride;
		_layouts[i].step = l.stepFunction;
		_layouts[i].rate = l.stepRate;
	}
	for (unsigned i = 0; i < 8; i++) {
		MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
		if (c.pixelFormat == MTLPixelFormatInvalid) continue;
		_ncolor = i + 1;
		_color[i].format = c.pixelFormat;
		_color[i].blend = c.blendingEnabled;
		_color[i].rgbOp = blend_op(c.rgbBlendOperation);
		_color[i].alphaOp = blend_op(c.alphaBlendOperation);
		_color[i].srcRGB = blend_factor(c.sourceRGBBlendFactor);
		_color[i].dstRGB = blend_factor(c.destinationRGBBlendFactor);
		_color[i].srcA = blend_factor(c.sourceAlphaBlendFactor);
		_color[i].dstA = blend_factor(c.destinationAlphaBlendFactor);
		MTLColorWriteMask m = c.writeMask;
		_color[i].mask[0] = (m & MTLColorWriteMaskRed) != 0;
		_color[i].mask[1] = (m & MTLColorWriteMaskGreen) != 0;
		_color[i].mask[2] = (m & MTLColorWriteMaskBlue) != 0;
		_color[i].mask[3] = (m & MTLColorWriteMaskAlpha) != 0;
	}
	_depthFormat = d.depthAttachmentPixelFormat;
	_stencilFormat = d.stencilAttachmentPixelFormat;
	_rasterEnabled = d.rasterizationEnabled;
	_alphaToCoverage = d.alphaToCoverageEnabled;
	return self;
}
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 0; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { MTLResourceID r = {(uint64_t)_prog->_program}; return r; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { (void)d; return 0; }
@end

/* ------------------------------------------------------------------ compute pipelines */

@implementation T290ComputePipeline {
	T290Shader *_shader;
	NSMutableDictionary *_bySize;
}
- (instancetype)initWithDevice:(T290Device *)device function:(T290Function *)f error:(NSError **)error
{
	if (!(self = [super initWithDevice:device])) return nil;
	if (![f isKindOfClass:[T290Function class]]) {
		if (error) *error = t290_error(@"compute function is not a T290Metal function");
		return nil;
	}
	_shader = [T290Shader compile:f error:error];
	if (!_shader) return nil;
	_bySize = [NSMutableDictionary dictionary];
	_threads = 256;
	return self;
}
/* GLSL needs the workgroup size at compile time: one program per size. */
- (T290Program *)programForSize:(MTLSize)s
{
	NSString *key = [NSString stringWithFormat:@"%lu,%lu,%lu", (unsigned long)s.width, (unsigned long)s.height, (unsigned long)s.depth];
	@synchronized(_bySize) {
		T290Program *p = _bySize[key];
		if (p) return p;
		T290Shader *sized = [T290Shader new];
		sized->refl = _shader->refl;
		sized->glsl = [_shader->glsl stringByReplacingOccurrencesOfString:@"#version 310 es\n" withString:
		    [NSString stringWithFormat:@"#version 310 es\n#define T290_LOCAL_X %lu\n#define T290_LOCAL_Y %lu\n#define T290_LOCAL_Z %lu\n",
		     (unsigned long)s.width, (unsigned long)s.height, (unsigned long)s.depth]];
		p = [T290Program new];
		NSError *e = nil;
		if (![p linkStages:@[sized] error:&e]) return nil;
		_bySize[key] = p;
		return p;
	}
}
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _threads; }
- (NSUInteger)threadExecutionWidth { return 32; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d { (void)d; return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { MTLResourceID r = {0}; return r; }
@end
