#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum {
    PATH_COUNT = 131072,
    SAMPLES_PER_PATH = 256,
    BOUNCE_COUNT = 8,
    BASE_SEED = 1337,
    REDUCTION_WIDTH = 64,
};

static const float INV_U24 = 1.0f / 16777216.0f;

typedef struct {
    float x;
    float y;
    float z;
} Vec3;

typedef struct {
    float x;
    float y;
    float z;
    float w;
} Vec4;

static uint32_t scramble_seed(uint32_t value) {
    uint32_t x = value * UINT32_C(747796405) + UINT32_C(2891336453);
    x = ((x >> ((x >> 28) + 4)) ^ x) * UINT32_C(277803737);
    return (x >> 22) ^ x;
}

static float next_random(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return (float)(x & UINT32_C(0x00ffffff)) * INV_U24;
}

static float next_signed_random(uint32_t *state) {
    return next_random(state) * 2.0f - 1.0f;
}

static float maximum(float left, float right) {
    return left > right ? left : right;
}

static Vec3 safe_normalize(Vec3 value) {
    float length_squared =
        value.x * value.x + value.y * value.y + value.z * value.z;
    float inverse_length = 1.0f / sqrtf(maximum(length_squared, 0.000001f));
    Vec3 result = {
        .x = value.x * inverse_length,
        .y = value.y * inverse_length,
        .z = value.z * inverse_length,
    };
    return result;
}

static float dot(Vec3 left, Vec3 right) {
    return left.x * right.x + left.y * right.y + left.z * right.z;
}

static Vec4 trace_path(uint32_t path_index, Vec3 sun_direction) {
    uint32_t state = scramble_seed(BASE_SEED ^ path_index);
    Vec3 radiance = {0.0f, 0.0f, 0.0f};

    for (uint32_t sample_index = 0; sample_index < SAMPLES_PER_PATH;
         ++sample_index) {
        state = scramble_seed(
            state ^ sample_index * UINT32_C(747796405) ^
            path_index * UINT32_C(2891336453));

        Vec3 throughput = {1.0f, 0.92f, 0.84f};
        Vec3 position = {
            next_signed_random(&state) * 0.5f,
            next_signed_random(&state) * 0.5f,
            next_random(&state) * 0.25f,
        };
        Vec3 direction = {
            next_signed_random(&state),
            next_signed_random(&state),
            next_random(&state) * 1.5f + 0.25f,
        };
        direction = safe_normalize(direction);
        Vec3 contribution = {0.0f, 0.0f, 0.0f};

        for (uint32_t bounce_index = 0; bounce_index < BOUNCE_COUNT;
             ++bounce_index) {
            Vec3 scatter = {
                next_signed_random(&state) + direction.x * 0.35f,
                next_signed_random(&state) + direction.y * 0.35f,
                next_random(&state) + direction.z * 0.5f,
            };
            scatter = safe_normalize(scatter);
            float sky =
                0.15f + 0.85f * maximum(scatter.y * 0.5f + 0.5f, 0.0f);
            float sun = maximum(dot(scatter, sun_direction), 0.0f);
            float sun_cubed = sun * sun * sun;

            contribution.x += throughput.x *
                              (0.08f * sky + 0.9f * sun_cubed);
            contribution.y += throughput.y *
                              (0.12f * sky + 0.78f * sun_cubed);
            contribution.z += throughput.z *
                              (0.18f * sky + 0.58f * sun_cubed);

            float travel = 0.2f + next_random(&state) * 1.8f;
            position.x += scatter.x * travel + 0.02f * direction.y;
            position.y += scatter.y * travel - 0.01f * direction.x;
            position.z += scatter.z * travel + 0.03f;
            Vec3 next_direction = {
                scatter.x + position.x * 0.015f,
                scatter.y + position.y * 0.015f,
                scatter.z + position.z * 0.015f,
            };
            direction = safe_normalize(next_direction);

            float fog = 0.94f - 0.03f * (float)bounce_index;
            throughput.x *= (0.90f + 0.06f * next_random(&state)) * fog;
            throughput.y *= (0.88f + 0.08f * next_random(&state)) * fog;
            throughput.z *= (0.86f + 0.10f * next_random(&state)) * fog;
        }

        radiance.x += contribution.x;
        radiance.y += contribution.y;
        radiance.z += contribution.z;
    }

    float inverse_samples = 1.0f / (float)SAMPLES_PER_PATH;
    Vec3 average = {
        radiance.x * inverse_samples,
        radiance.y * inverse_samples,
        radiance.z * inverse_samples,
    };
    Vec4 result = {
        .x = average.x,
        .y = average.y,
        .z = average.z,
        .w = dot(average, (Vec3){0.2126f, 0.7152f, 0.0722f}),
    };
    return result;
}

static void reduce(const Vec4 *source, size_t element_count, Vec4 *target) {
    size_t group_count =
        (element_count + REDUCTION_WIDTH - 1) / REDUCTION_WIDTH;
    for (size_t group = 0; group < group_count; ++group) {
        Vec4 scratch[REDUCTION_WIDTH] = {{0.0f, 0.0f, 0.0f, 0.0f}};
        for (size_t lane = 0; lane < REDUCTION_WIDTH; ++lane) {
            size_t source_index = group * REDUCTION_WIDTH + lane;
            if (source_index < element_count) {
                scratch[lane] = source[source_index];
            }
        }
        for (size_t stride = REDUCTION_WIDTH / 2; stride > 0; stride /= 2) {
            for (size_t lane = 0; lane < stride; ++lane) {
                scratch[lane].x += scratch[lane + stride].x;
                scratch[lane].y += scratch[lane + stride].y;
                scratch[lane].z += scratch[lane + stride].z;
                scratch[lane].w += scratch[lane + stride].w;
            }
        }
        target[group] = scratch[0];
    }
}

static int write_output(const char *path, const Vec4 *value) {
    FILE *output = fopen(path, "wb");
    if (output == NULL) {
        return 1;
    }
    size_t written = fwrite(value, sizeof(*value), 1, output);
    int close_status = fclose(output);
    return written == 1 && close_status == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <output-f32le-bin>\n", argv[0]);
        return 2;
    }
    Vec4 *paths = calloc(PATH_COUNT, sizeof(*paths));
    Vec4 *first_reduction = calloc(PATH_COUNT / REDUCTION_WIDTH,
                                   sizeof(*first_reduction));
    Vec4 *second_reduction = calloc(
        PATH_COUNT / REDUCTION_WIDTH / REDUCTION_WIDTH,
        sizeof(*second_reduction));
    Vec4 final_reduction = {0.0f, 0.0f, 0.0f, 0.0f};
    if (paths == NULL || first_reduction == NULL || second_reduction == NULL) {
        fprintf(stderr, "monte-carlo reference allocation failed\n");
        return 1;
    }

    Vec3 sun_direction = safe_normalize((Vec3){0.35f, 0.82f, 0.44f});
#pragma omp parallel for schedule(static)
    for (uint32_t path_index = 0; path_index < PATH_COUNT; ++path_index) {
        paths[path_index] = trace_path(path_index, sun_direction);
    }
    reduce(paths, PATH_COUNT, first_reduction);
    reduce(first_reduction, PATH_COUNT / REDUCTION_WIDTH, second_reduction);
    reduce(second_reduction,
           PATH_COUNT / REDUCTION_WIDTH / REDUCTION_WIDTH,
           &final_reduction);

    int status = write_output(argv[1], &final_reduction);
    free(paths);
    free(first_reduction);
    free(second_reduction);
    return status;
}
