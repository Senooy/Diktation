// API C du cœur Rust (src/ffi.rs).
#pragma once
#include <stdbool.h>

typedef void (*dk_callback)(const char *event_json, void *user);

// Lance le cœur. `cb` est appelé depuis le fil du cœur, pas le fil principal.
bool dk_start(dk_callback cb, void *user);
// Commande JSON de l'interface ({"cmd":"set_prefs","prefs":{…}}, …).
void dk_send(const char *json);
// Instantané JSON complet ; à libérer avec dk_free.
char *dk_state(void);
void dk_free(char *s);
