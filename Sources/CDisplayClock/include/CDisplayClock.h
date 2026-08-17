#ifndef CIDA_DISPLAY_CLOCK_H
#define CIDA_DISPLAY_CLOCK_H

#include <stdbool.h>
#include <stdint.h>

typedef void (*CidaDisplayClockCallback)(void *context);
typedef struct CidaDisplayClock CidaDisplayClock;

CidaDisplayClock *cida_display_clock_create(uint32_t display_id,
                                            CidaDisplayClockCallback callback,
                                            void *context);
bool cida_display_clock_start(CidaDisplayClock *clock);
void cida_display_clock_stop(CidaDisplayClock *clock);
void cida_display_clock_destroy(CidaDisplayClock *clock);

#endif
