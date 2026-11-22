#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <cmath>
#include <cstring>

namespace ifd {
// Validate the host getter ABI once per runtime class, then dispatch normally.
// Do not allocate NSInvocation and NSMethodSignature objects for every frame.
class Getter {
    Class class_ = Nil;
protected:
    SEL selector_;
    char type_ = 0;
    explicit Getter(const char *name) : selector_(sel_registerName(name)) {}
    bool validate(id object) {
        if (!object) return false;
        Class cls = object_getClass(object);
        if (cls != class_) {
            class_ = cls; type_ = 0;
            NSMethodSignature *s = [object methodSignatureForSelector:selector_];
            if (s && s.numberOfArguments == 2) {
                const char *type = s.methodReturnType;
                while (*type && std::strchr("rnNoORV", *type)) ++type;
                type_ = *type;
            }
        }
        return type_ != 0;
    }
};
class ObjectGetter : Getter {
public:
    explicit ObjectGetter(const char *name) : Getter(name) {}
    id read(id object) {
        @try {
            if (!validate(object) || type_ != '@') return nil;
            return ((id (*)(id, SEL))objc_msgSend)(object, selector_);
        } @catch (__unused NSException *e) { return nil; }
    }
};
class NumberGetter : Getter {
public:
    explicit NumberGetter(const char *name) : Getter(name) {}
    bool read(id object, double &value) {
        @try {
            if (!validate(object)) return false;
            switch (type_) {
                case 'd': value = ((double (*)(id, SEL))objc_msgSend)(object, selector_); break;
                case 'f': value = ((float (*)(id, SEL))objc_msgSend)(object, selector_); break;
                case 'B': value = ((bool (*)(id, SEL))objc_msgSend)(object, selector_); break;
                case 'c': value = ((signed char (*)(id, SEL))objc_msgSend)(object, selector_); break;
                default: return false;
            }
            return std::isfinite(value);
        } @catch (__unused NSException *e) { return false; }
    }
};
struct PlayerGetters {
    ObjectGetter player{"player"}, container{"modelContainer"};
    NumberGetter time{"currentTime"}, paused{"isPaused"}, rate{"playbackRate"};
};
} // namespace ifd
