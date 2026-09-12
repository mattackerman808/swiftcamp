#include "USBTransport.h"

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// USB class 6 is still image capture, which is what MTP and PTP ride on.
#define USB_CLASS_STILL_IMAGE 6

struct sc_usb_handle {
    IOUSBDeviceInterface300 **device;
    IOUSBInterfaceInterface300 **interface;
    UInt8 pipe_in;
    UInt8 pipe_out;
    UInt16 max_packet_out;
};

// MARK: - Small helpers

static void copy_string_property(io_service_t service, CFStringRef key,
                                 char *out, size_t capacity) {
    out[0] = '\0';
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString(value, out, (CFIndex)capacity, kCFStringEncodingUTF8);
    }
    CFRelease(value);
}

static uint32_t number_property(io_service_t service, CFStringRef key) {
    uint32_t result = 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &result);
    }
    CFRelease(value);
    return result;
}

/// IOKit addresses endpoints by a pipe index, counting from 1 in the order
/// the interface reports them. That number is not the endpoint address in the
/// descriptor, and confusing the two reads from the wrong endpoint rather
/// than failing, which is a slow thing to notice.
static bool classify_pipes(IOUSBInterfaceInterface300 **intf,
                           UInt8 *pipe_in, UInt8 *pipe_out, UInt16 *max_packet_out) {
    UInt8 count = 0;
    if ((*intf)->GetNumEndpoints(intf, &count) != kIOReturnSuccess) return false;

    bool found_in = false, found_out = false;
    for (UInt8 i = 1; i <= count; i++) {
        UInt8 direction, number, transfer_type, interval;
        UInt16 packet_size;
        if ((*intf)->GetPipeProperties(intf, i, &direction, &number, &transfer_type,
                                       &packet_size, &interval) != kIOReturnSuccess) {
            continue;
        }
        if (transfer_type != kUSBBulk) continue;   // the interrupt pipe carries events we ignore

        if (direction == kUSBIn && !found_in) {
            *pipe_in = i;
            found_in = true;
        } else if (direction == kUSBOut && !found_out) {
            *pipe_out = i;
            *max_packet_out = packet_size;
            found_out = true;
        }
    }
    return found_in && found_out;
}

// MARK: - Enumeration

int sc_usb_enumerate(sc_usb_device_info *out, int capacity) {
    if (!out || capacity <= 0) return SC_USB_PARAM;

    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return SC_USB_OTHER;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) {
        return SC_USB_OTHER;
    }

    int found = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) && found < capacity) {
        sc_usb_device_info *info = &out[found];
        memset(info, 0, sizeof(*info));

        info->vendor_id   = (uint16_t)number_property(service, CFSTR(kUSBVendorID));
        info->product_id  = (uint16_t)number_property(service, CFSTR(kUSBProductID));
        info->location_id = number_property(service, CFSTR("locationID"));
        copy_string_property(service, CFSTR("USB Vendor Name"), info->vendor_name, SC_USB_NAME_MAX);
        copy_string_property(service, CFSTR("USB Product Name"), info->product_name, SC_USB_NAME_MAX);

        // The interface class lives on child nodes, not on the device, and
        // only once the device has been configured. A device that reports
        // nothing here is not necessarily uninteresting — it may simply not
        // have been probed yet — so this is a hint for sorting the list, not
        // a filter.
        io_iterator_t children = 0;
        if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(children))) {
                if (number_property(child, CFSTR(kUSBInterfaceClass)) == USB_CLASS_STILL_IMAGE) {
                    info->has_still_image_interface = true;
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(children);
        }

        IOObjectRelease(service);
        found++;
    }
    IOObjectRelease(iterator);
    return found;
}

// MARK: - Opening

/// Walks the device's interfaces and claims one that can carry MTP.
///
/// Two passes rather than one. A Garmin presents several interfaces and only
/// one of them is still image; taking the first with bulk endpoints can land
/// on something else entirely and then every transfer times out for no
/// visible reason.
static IOUSBInterfaceInterface300 **claim_interface(IOUSBDeviceInterface300 **device,
                                                    bool require_still_image,
                                                    UInt8 *pipe_in, UInt8 *pipe_out,
                                                    UInt16 *max_packet_out) {
    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass    = require_still_image ? USB_CLASS_STILL_IMAGE
                                                     : kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = 0;
    if ((*device)->CreateInterfaceIterator(device, &request, &iterator) != kIOReturnSuccess) {
        return NULL;
    }

    IOUSBInterfaceInterface300 **claimed = NULL;
    io_service_t service;
    while (!claimed && (service = IOIteratorNext(iterator))) {
        SInt32 score = 0;
        IOCFPlugInInterface **plugin = NULL;
        kern_return_t kr = IOCreatePlugInInterfaceForService(
            service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS || !plugin) continue;

        IOUSBInterfaceInterface300 **candidate = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
                                  (LPVOID *)&candidate);
        (*plugin)->Release(plugin);
        if (!candidate) continue;

        if ((*candidate)->USBInterfaceOpen(candidate) != kIOReturnSuccess) {
            (*candidate)->Release(candidate);
            continue;
        }

        if (classify_pipes(candidate, pipe_in, pipe_out, max_packet_out)) {
            claimed = candidate;
        } else {
            (*candidate)->USBInterfaceClose(candidate);
            (*candidate)->Release(candidate);
        }
    }
    IOObjectRelease(iterator);
    return claimed;
}

sc_usb_handle *sc_usb_open(uint32_t location_id, sc_usb_error *error) {
    if (error) *error = SC_USB_OK;

    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) {
        if (error) *error = SC_USB_OTHER;
        return NULL;
    }

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) {
        if (error) *error = SC_USB_OTHER;
        return NULL;
    }

    io_service_t service = 0, candidate;
    while ((candidate = IOIteratorNext(iterator))) {
        if (number_property(candidate, CFSTR("locationID")) == location_id) {
            service = candidate;
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);

    if (!service) {
        if (error) *error = SC_USB_NOT_FOUND;
        return NULL;
    }

    SInt32 score = 0;
    IOCFPlugInInterface **plugin = NULL;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) {
        if (error) *error = SC_USB_ACCESS;
        return NULL;
    }

    IOUSBDeviceInterface300 **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                              (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (!device) {
        if (error) *error = SC_USB_ACCESS;
        return NULL;
    }

    // Seize if a plain open is refused. Something else on the system has
    // usually looked at the device already, and without the fallback this is
    // where it stops.
    if ((*device)->USBDeviceOpen(device) != kIOReturnSuccess &&
        (*device)->USBDeviceOpenSeize(device) != kIOReturnSuccess) {
        (*device)->Release(device);
        if (error) *error = SC_USB_ACCESS;
        return NULL;
    }

    IOUSBConfigurationDescriptorPtr configuration = NULL;
    if ((*device)->GetConfigurationDescriptorPtr(device, 0, &configuration) == kIOReturnSuccess) {
        (*device)->SetConfiguration(device, configuration->bConfigurationValue);
    }

    UInt8 pipe_in = 0, pipe_out = 0;
    UInt16 max_packet_out = 512;
    IOUSBInterfaceInterface300 **interface =
        claim_interface(device, true, &pipe_in, &pipe_out, &max_packet_out);
    if (!interface) {
        interface = claim_interface(device, false, &pipe_in, &pipe_out, &max_packet_out);
    }
    if (!interface) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = SC_USB_NOT_FOUND;
        return NULL;
    }

    sc_usb_handle *handle = calloc(1, sizeof(sc_usb_handle));
    handle->device = device;
    handle->interface = interface;
    handle->pipe_in = pipe_in;
    handle->pipe_out = pipe_out;
    handle->max_packet_out = max_packet_out ? max_packet_out : 512;
    return handle;
}

// MARK: - Transfers

int sc_usb_bulk_write(sc_usb_handle *h, const uint8_t *data, int length, int timeout_ms) {
    if (!h || !h->interface) return SC_USB_PARAM;
    UInt32 size = (UInt32)length;
    IOReturn kr = (*h->interface)->WritePipeTO(h->interface, h->pipe_out,
                                               (void *)data, size,
                                               timeout_ms, timeout_ms);
    if (kr == kIOUSBTransactionTimeout) return SC_USB_TIMEOUT;
    if (kr != kIOReturnSuccess) return SC_USB_IO;
    return length;
}

int sc_usb_bulk_read(sc_usb_handle *h, uint8_t *data, int length, int timeout_ms) {
    if (!h || !h->interface) return SC_USB_PARAM;
    UInt32 size = (UInt32)length;
    IOReturn kr = (*h->interface)->ReadPipeTO(h->interface, h->pipe_in,
                                              data, &size,
                                              timeout_ms, timeout_ms);
    if (kr == kIOUSBTransactionTimeout) return SC_USB_TIMEOUT;
    if (kr != kIOReturnSuccess) return SC_USB_IO;
    return (int)size;
}

uint16_t sc_usb_max_packet_out(sc_usb_handle *h) {
    return h ? h->max_packet_out : 512;
}

sc_usb_error sc_usb_clear_halt_in(sc_usb_handle *h) {
    if (!h || !h->interface) return SC_USB_PARAM;
    return (*h->interface)->ClearPipeStallBothEnds(h->interface, h->pipe_in) == kIOReturnSuccess
        ? SC_USB_OK : SC_USB_PIPE;
}

sc_usb_error sc_usb_clear_halt_out(sc_usb_handle *h) {
    if (!h || !h->interface) return SC_USB_PARAM;
    return (*h->interface)->ClearPipeStallBothEnds(h->interface, h->pipe_out) == kIOReturnSuccess
        ? SC_USB_OK : SC_USB_PIPE;
}

sc_usb_error sc_usb_reset(sc_usb_handle *h) {
    if (!h || !h->device) return SC_USB_PARAM;
    return (*h->device)->ResetDevice(h->device) == kIOReturnSuccess ? SC_USB_OK : SC_USB_IO;
}

void sc_usb_close(sc_usb_handle *h) {
    if (!h) return;
    if (h->interface) {
        (*h->interface)->USBInterfaceClose(h->interface);
        (*h->interface)->Release(h->interface);
    }
    if (h->device) {
        (*h->device)->USBDeviceClose(h->device);
        (*h->device)->Release(h->device);
    }
    free(h);
}

#else

// iOS has no IOKit USB. The declarations stay so shared code still compiles;
// nothing on that platform can call them meaningfully.
int sc_usb_enumerate(sc_usb_device_info *out, int capacity) { (void)out; (void)capacity; return 0; }
sc_usb_handle *sc_usb_open(uint32_t l, sc_usb_error *e) { (void)l; if (e) *e = SC_USB_NOT_FOUND; return NULL; }
int sc_usb_bulk_write(sc_usb_handle *h, const uint8_t *d, int n, int t) { (void)h;(void)d;(void)n;(void)t; return SC_USB_NOT_FOUND; }
int sc_usb_bulk_read(sc_usb_handle *h, uint8_t *d, int n, int t) { (void)h;(void)d;(void)n;(void)t; return SC_USB_NOT_FOUND; }
uint16_t sc_usb_max_packet_out(sc_usb_handle *h) { (void)h; return 512; }
sc_usb_error sc_usb_clear_halt_in(sc_usb_handle *h) { (void)h; return SC_USB_NOT_FOUND; }
sc_usb_error sc_usb_clear_halt_out(sc_usb_handle *h) { (void)h; return SC_USB_NOT_FOUND; }
sc_usb_error sc_usb_reset(sc_usb_handle *h) { (void)h; return SC_USB_NOT_FOUND; }
void sc_usb_close(sc_usb_handle *h) { (void)h; }

#endif
