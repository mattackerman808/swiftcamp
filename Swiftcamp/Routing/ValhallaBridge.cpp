#include "ValhallaBridge.h"

#include <valhalla/baldr/rapidjson_utils.h>
#include <valhalla/exceptions.h>
#include <valhalla/tyr/actor.h>

#include <boost/property_tree/ptree.hpp>

#include <cstdlib>
#include <cstring>
#include <exception>
#include <sstream>
#include <string>

struct valhalla_engine {
  boost::property_tree::ptree config;
  valhalla::tyr::actor_t actor;

  explicit valhalla_engine(boost::property_tree::ptree c)
      // auto_cleanup: the workers drop their per-request state after each
      // call, so a long-lived engine does not hold the last route's graph
      // tiles in memory between requests.
      : config(std::move(c)), actor(config, true) {}
};

static char *copy(const std::string &s) {
  char *out = static_cast<char *>(std::malloc(s.size() + 1));
  if (out) std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

static void fail(char **error, const std::string &message) {
  if (error) *error = copy(message);
}

extern "C" {

valhalla_engine *valhalla_engine_open(const char *config_json, char **error) {
  try {
    boost::property_tree::ptree config;
    std::stringstream stream(config_json ? config_json : "");
    rapidjson::read_json(stream, config);
    return new valhalla_engine(std::move(config));
  } catch (const std::exception &e) {
    fail(error, e.what());
  } catch (...) {
    fail(error, "unknown failure opening the routing engine");
  }
  return nullptr;
}

void valhalla_engine_close(valhalla_engine *engine) {
  delete engine;
}

char *valhalla_engine_route(valhalla_engine *engine, const char *request_json, char **error) {
  if (!engine) {
    fail(error, "no engine");
    return nullptr;
  }
  try {
    return copy(engine->actor.route(request_json ? request_json : ""));
  } catch (const valhalla::valhalla_exception_t &e) {
    // Valhalla's own errors carry a code and a message, e.g. 442 "No path
    // could be found for input". The message is what the user needs.
    fail(error, e.what());
  } catch (const std::exception &e) {
    fail(error, e.what());
  } catch (...) {
    fail(error, "unknown failure routing");
  }
  return nullptr;
}

void valhalla_free(char *string) {
  std::free(string);
}

}
