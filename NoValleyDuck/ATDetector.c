#include "ATDetector.h"
#include "apriltag.h"
#include "tag25h9.h"
#include "apriltag_pose.h"
#include "common/image_u8.h"
#include "common/zarray.h"
#include "common/matd.h"
#include <stdlib.h>

typedef struct { apriltag_detector_t *td; apriltag_family_t *tf; } at_ctx;

void *at_create(double quad_decimate, int nthreads) {
    at_ctx *c = calloc(1, sizeof(at_ctx));
    c->tf = tag25h9_create();
    c->td = apriltag_detector_create();
    apriltag_detector_add_family_bits(c->td, c->tf, 1); // correct at most 1 bit
    c->td->quad_decimate     = (float)quad_decimate;    // 1.0 = full resolution, best range
    c->td->quad_sigma        = 0.0f;
    c->td->nthreads          = nthreads;
    c->td->refine_edges      = 1;
    c->td->decode_sharpening = 0.25;
    return c;
}

void at_set_decimate(void *ctx, double q) { ((at_ctx *)ctx)->td->quad_decimate = (float)q; }

int at_detect(void *ctx, const uint8_t *gray, int width, int height, int stride,
              double fx, double fy, double cx, double cy,
              at_detection *out, int max_out) {
    at_ctx *c = (at_ctx *)ctx;
    image_u8_t im = { .width = width, .height = height, .stride = stride, .buf = (uint8_t *)gray };
    zarray_t *dets = apriltag_detector_detect(c->td, &im);
    int n = zarray_size(dets), k = 0;
    for (int i = 0; i < n && k < max_out; i++) {
        apriltag_detection_t *d;
        zarray_get(dets, i, &d);
        at_detection *o = &out[k++];
        o->id = d->id; o->hamming = d->hamming; o->decision_margin = d->decision_margin;
        o->center_x = d->c[0]; o->center_y = d->c[1];
        for (int j = 0; j < 4; j++) { o->corners[2*j] = d->p[j][0]; o->corners[2*j+1] = d->p[j][1]; }
        o->has_pose = 0;
        if (fx > 0) {
            apriltag_detection_info_t info = { .det = d, .tagsize = 1.0,
                                               .fx = fx, .fy = fy, .cx = cx, .cy = cy };
            apriltag_pose_t pose;
            o->pose_error = estimate_tag_pose(&info, &pose);
            o->tx = MATD_EL(pose.t, 0, 0); o->ty = MATD_EL(pose.t, 1, 0); o->tz = MATD_EL(pose.t, 2, 0);
            for (int j = 0; j < 9; j++) o->r[j] = MATD_EL(pose.R, j / 3, j % 3);
            o->has_pose = 1;
            matd_destroy(pose.R); matd_destroy(pose.t);
        }
    }
    apriltag_detections_destroy(dets);
    return k;
}

void at_destroy(void *ctx) {
    at_ctx *c = (at_ctx *)ctx;
    apriltag_detector_destroy(c->td);
    tag25h9_destroy(c->tf);
    free(c);
}
