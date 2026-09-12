#ifndef SWIFTCAMP_USB_TRANSPORT_H
#define SWIFTCAMP_USB_TRANSPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Raw USB transport, over IOKit.
///
/// Ported from `~/git/swift-hakchi2/USBBridge/src/usb_device.c`, which drives
/// a Nintendo console over USB from a Swift Mac app and is proven against
/// real hardware. The parts kept are the ones that were expensive to get
/// right: opening a device another driver already holds, walking interfaces
/// to find usable endpoints, and mapping endpoint addresses to IOKit's pipe
/// indices, which are not the same numbers.
///
/// What is new here is enumeration — that project only ever opened one known
/// device — and picking the still-image interface, which is where MTP lives.
///
/// IOKit rather than libusb. A Mac app that is not sandboxed reaches USB
/// through IOKit with no entitlement and no extra dependency, and vendoring a
/// second USB stack when this one already exists would be strange.

#ifdef __cplusplus
extern "C" {
#endif

#define SC_USB_MAX_DEVICES 64
#define SC_USB_NAME_MAX 128

typedef enum {
    SC_USB_OK = 0,
    SC_USB_NOT_FOUND = -1,
    SC_USB_ACCESS = -2,
    SC_USB_IO = -3,
    SC_USB_TIMEOUT = -4,
    SC_USB_PIPE = -5,
    SC_USB_PARAM = -6,
    SC_USB_OTHER = -99,
} sc_usb_error;

/// One device on the bus.
typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    /// IOKit's per-port address. Stable while the device stays plugged into
    /// the same port, and the only way to tell two identical devices apart —
    /// vendor and product ids cannot.
    uint32_t location_id;
    char vendor_name[SC_USB_NAME_MAX];
    char product_name[SC_USB_NAME_MAX];
    /// True when some interface declares USB class 6, still image capture,
    /// which is the class MTP and PTP are carried on.
    bool has_still_image_interface;
} sc_usb_device_info;

/// Fills `out` with up to `capacity` devices. Returns the count, or negative
/// on failure.
int sc_usb_enumerate(sc_usb_device_info *out, int capacity);

typedef struct sc_usb_handle sc_usb_handle;

/// Opens the device at `location_id` and claims an interface with bulk
/// endpoints in both directions, preferring a still-image one.
sc_usb_handle *sc_usb_open(uint32_t location_id, sc_usb_error *error);

int sc_usb_bulk_write(sc_usb_handle *h, const uint8_t *data, int length, int timeout_ms);
int sc_usb_bulk_read(sc_usb_handle *h, uint8_t *data, int length, int timeout_ms);

/// Endpoint packet size. MTP needs it: a transfer whose length is an exact
/// multiple of it has to be followed by a zero-length packet, or the device
/// waits for more and the read times out.
uint16_t sc_usb_max_packet_out(sc_usb_handle *h);

/// Reads one event off the interrupt pipe.
///
/// MTP announces things on it — `ObjectAdded` when a write lands — and a
/// responder that cannot deliver an event will not send the response after it.
/// Reads raise no events, so a host that ignores this pipe works perfectly
/// until the first time it writes something.
int sc_usb_event_read(sc_usb_handle *h, uint8_t *data, int length, int timeout_ms);

/// Asks the device, over the control pipe, what it thinks is happening.
///
/// The only question that still gets an answer when the bulk pipes are stuck.
/// Fills `out` with a little-endian length, then a response code: `0x2001`
/// means the device considers itself idle, and anything else names what it is
/// still holding. Returns the byte count, or a negative `sc_usb_error`.
int sc_usb_mtp_device_status(sc_usb_handle *h, uint8_t *out, int capacity);

/// Withdraws a request the device is still holding.
///
/// Without this an abandoned transaction's reply stays queued and is handed to
/// whoever reads next — including the next launch of the app, which then reads
/// it as the answer to its own first question.
sc_usb_error sc_usb_mtp_cancel(sc_usb_handle *h, uint32_t transaction);

/// Clears the responder's own state: any open session, any transaction it is
/// still holding. A class request, not the port reset `sc_usb_reset` performs
/// — the device keeps its connection and carries on with whatever else it is
/// doing.
sc_usb_error sc_usb_mtp_reset(sc_usb_handle *h);

/// Whether a pipe is running, stalled, or something else: 0, 1, 2. `which` is
/// 0 for bulk in, 1 for bulk out, 2 for the event pipe. Read-only — it asks
/// the host controller and sends nothing to the device.
int sc_usb_pipe_status(sc_usb_handle *h, int which);

sc_usb_error sc_usb_clear_halt_in(sc_usb_handle *h);
sc_usb_error sc_usb_clear_halt_out(sc_usb_handle *h);

/// Resets the device, which is what clears one left mid-transaction by a
/// failed transfer. The same thing unplugging it does, without the walk.
sc_usb_error sc_usb_reset(sc_usb_handle *h);

void sc_usb_close(sc_usb_handle *h);

#ifdef __cplusplus
}
#endif

#endif /* SWIFTCAMP_USB_TRANSPORT_H */
