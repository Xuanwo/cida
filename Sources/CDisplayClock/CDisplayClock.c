#include "CDisplayClock.h"

#include <CoreVideo/CVDisplayLink.h>
#include <CoreVideo/CVHostTime.h>
#include <stdlib.h>

struct CidaDisplayClock {
  CVDisplayLinkRef display_link;
  CidaDisplayClockCallback callback;
  void *context;
};

static CVReturn cida_display_clock_output(CVDisplayLinkRef display_link,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *output_time,
                                          CVOptionFlags flags_in,
                                          CVOptionFlags *flags_out,
                                          void *context) {
  (void)display_link;
  (void)now;
  (void)output_time;
  (void)flags_in;
  (void)flags_out;
  CidaDisplayClock *clock = context;
  double callback_time_seconds =
      (double)CVGetCurrentHostTime() / CVGetHostClockFrequency();
  clock->callback(clock->context, callback_time_seconds);
  return kCVReturnSuccess;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

CidaDisplayClock *cida_display_clock_create(uint32_t display_id,
                                            CidaDisplayClockCallback callback,
                                            void *context) {
  if (callback == NULL) {
    return NULL;
  }
  CidaDisplayClock *clock = calloc(1, sizeof(CidaDisplayClock));
  if (clock == NULL) {
    return NULL;
  }
  clock->callback = callback;
  clock->context = context;
  if (CVDisplayLinkCreateWithCGDisplay(display_id, &clock->display_link) !=
      kCVReturnSuccess) {
    free(clock);
    return NULL;
  }
  if (CVDisplayLinkSetOutputCallback(clock->display_link,
                                     cida_display_clock_output,
                                     clock) != kCVReturnSuccess) {
    CVDisplayLinkRelease(clock->display_link);
    free(clock);
    return NULL;
  }
  return clock;
}

bool cida_display_clock_start(CidaDisplayClock *clock) {
  return clock != NULL &&
         CVDisplayLinkStart(clock->display_link) == kCVReturnSuccess;
}

void cida_display_clock_stop(CidaDisplayClock *clock) {
  if (clock != NULL && CVDisplayLinkIsRunning(clock->display_link)) {
    CVDisplayLinkStop(clock->display_link);
  }
}

void cida_display_clock_destroy(CidaDisplayClock *clock) {
  if (clock == NULL) {
    return;
  }
  cida_display_clock_stop(clock);
  CVDisplayLinkRelease(clock->display_link);
  free(clock);
}

#pragma clang diagnostic pop
