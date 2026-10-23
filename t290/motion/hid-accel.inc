/* Included at the end of SweetHID.cpp, SM-T290 only. */
#if defined(SWEET_T290)
extern "C" int sweet_t290_accel_init(void);
extern "C" int sweet_t290_accel_read(int32_t xyz[3]);
extern "C" void sweet_t290_accel_stop(void);

class SweetHIDAccel : public IOHIDEventService {
	OSDeclareDefaultStructors(SweetHIDAccel);
public:
	virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
protected:
	virtual UInt32 getPrimaryUsagePage() APPLE_KEXT_OVERRIDE { return kHIDPage_Sensor; }
	virtual UInt32 getPrimaryUsage() APPLE_KEXT_OVERRIDE { return kHIDUsage_Snsr_Motion_Accelerometer3D; }
	virtual UInt32 getProductID() APPLE_KEXT_OVERRIDE { return 3; }
	virtual UInt32 getReportInterval() APPLE_KEXT_OVERRIDE { return 40000; }
	virtual OSString *getProduct() APPLE_KEXT_OVERRIDE { return OSString::withCString("SM-T290 KXTJ3"); }
private:
	static void fired(OSObject *owner, IOTimerEventSource *sender);
	IOTimerEventSource *fTimer;
	unsigned fSequence, fErrors;
};
OSDefineMetaClassAndStructors(SweetHIDAccel, IOHIDEventService);

bool SweetHIDAccel::start(IOService *provider)
{
	/* Opt-in until the board bus and userland subscription are boot-verified. */
	int enable = 0;
	PE_parse_boot_argn("t290accel", &enable, sizeof(enable));
	if (!enable) return false;
	if (!IOHIDEventService::start(provider)) return false;
	int err = sweet_t290_accel_init();
	if (err) { IOLog("SWEET ACCEL: service unavailable err=%d\n", err); return false; }
	fTimer = IOTimerEventSource::timerEventSource(this, &SweetHIDAccel::fired);
	if (!fTimer || _hidWorkLoop->addEventSource(fTimer) != kIOReturnSuccess) {
		OSSafeReleaseNULL(fTimer);
		sweet_t290_accel_stop();
		return false;
	}
	registerService();
	fTimer->setTimeoutMS(100); /* allow several conversion periods after PC1 */
	IOLog("SWEET ACCEL: registered, 25Hz, +/-2g, gravity 16.16\n");
	return true;
}
void SweetHIDAccel::stop(IOService *provider)
{
	if (fTimer) {
		fTimer->cancelTimeout();
		_hidWorkLoop->removeEventSource(fTimer);
		OSSafeReleaseNULL(fTimer);
	}
	sweet_t290_accel_stop();
	IOHIDEventService::stop(provider);
}
void SweetHIDAccel::fired(OSObject *owner, IOTimerEventSource *sender)
{
	SweetHIDAccel *self = OSDynamicCast(SweetHIDAccel, owner);
	if (!self) return;
	int32_t xyz[3];
	int err = sweet_t290_accel_read(xyz);
	if (err) {
		if (++self->fErrors >= 5) {
			IOLog("SWEET ACCEL: stopped after 5 bus errors, last=%d\n", err);
			sweet_t290_accel_stop();
			return;
		}
	} else {
		self->fErrors = 0;
		unsigned seq = ++self->fSequence;
		IOHIDEvent *event = IOHIDEvent::accelerometerEvent(mach_absolute_time(),
		    xyz[0], xyz[1], xyz[2], kIOHIDMotionTypeNormal, 0, seq);
		if (event) { self->dispatchEvent(event); event->release(); }
		if (seq <= 5 || seq % 125 == 0) {
			IOLockLock(self->_clientLock);
			unsigned clients = self->_clients->getCount();
			IOLockUnlock(self->_clientLock);
			IOLog("SWEET ACCEL: seq=%u xyz=%d,%d,%d clients=%u\n", seq,
			    xyz[0], xyz[1], xyz[2], clients);
		}
	}
	sender->setTimeoutMS(40);
}
#endif
