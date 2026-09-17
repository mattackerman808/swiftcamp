// A C face on Valhalla's actor, so Swift never sees a C++ type.
//
// Valhalla is C++20 with Boost property trees in its public API. Swift's
// C++ interop cannot digest that, and does not need to: the whole
// conversation is JSON in and JSON out, which is what `actor_t` speaks
// anyway. Four functions and an opaque handle are the entire surface.

#ifndef SWIFTCAMP_VALHALLA_BRIDGE_H
#define SWIFTCAMP_VALHALLA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct valhalla_engine valhalla_engine;

/// Opens an engine on the tiles named in `config_json`, Valhalla's own
/// configuration document. Returns NULL on failure with `*error` set to a
/// message the caller releases with `valhalla_free`.
valhalla_engine *valhalla_engine_open(const char *config_json, char **error);

void valhalla_engine_close(valhalla_engine *engine);

/// Runs a route request, Valhalla's JSON API, and returns the JSON reply.
/// The caller releases it with `valhalla_free`. Returns NULL on failure
/// with `*error` set, likewise owned by the caller.
///
/// Not thread-safe: an engine answers one request at a time.
char *valhalla_engine_route(valhalla_engine *engine, const char *request_json, char **error);

void valhalla_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
