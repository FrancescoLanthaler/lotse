#ifndef AT_DETECTOR_H
#define AT_DETECTOR_H
#include <stdint.h>

typedef struct {
    int    id;
    int    hamming;          // bits corrected; only 0 is accepted for speech
    float  decision_margin;  // higher = more confident
    double center_x, center_y;
    double corners[8];       // x0,y0,...,x3,y3 in pixels
    int    has_pose;
    double tx, ty, tz;       // translation for tag size 1.0 (scale in Swift)
    double pose_error;
} at_detection;

void *at_create(double quad_decimate, int nthreads);
void  at_set_decimate(void *ctx, double quad_decimate);
int   at_detect(void *ctx, const uint8_t *gray, int width, int height, int stride,
                double fx, double fy, double cx, double cy,
                at_detection *out, int max_out);
void  at_destroy(void *ctx);
#endif
