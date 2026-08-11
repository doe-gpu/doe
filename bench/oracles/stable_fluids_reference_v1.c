#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum {
    GRID_WIDTH = 256,
    GRID_HEIGHT = 256,
    CELL_COUNT = GRID_WIDTH * GRID_HEIGHT,
    PRESSURE_PAIRS = 9,
    SIMULATION_STEPS = 4,
};

static const float TIME_STEP = 0.1f;
static const float VELOCITY_DISSIPATION = 0.9965f;
static const float DYE_DISSIPATION = 0.9925f;
static const float FORCE_SCALE = 0.35f;
static const float INV_U24 = 1.0f / 16777216.0f;

typedef struct {
    float x;
    float y;
} Vec2;

static uint32_t scramble_seed(uint32_t value) {
    uint32_t x = value * UINT32_C(747796405) + UINT32_C(2891336453);
    x = ((x >> ((x >> 28) + 4)) ^ x) * UINT32_C(277803737);
    return (x >> 22) ^ x;
}

static size_t cell_index(int x, int y) {
    return (size_t)y * GRID_WIDTH + (size_t)x;
}

static int clamp_int(int value, int maximum) {
    if (value < 0) {
        return 0;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static float clamp_float(float value, float maximum) {
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static Vec2 read_velocity(const Vec2 *field, int x, int y) {
    x = clamp_int(x, GRID_WIDTH - 1);
    y = clamp_int(y, GRID_HEIGHT - 1);
    return field[cell_index(x, y)];
}

static float read_scalar(const float *field, int x, int y) {
    x = clamp_int(x, GRID_WIDTH - 1);
    y = clamp_int(y, GRID_HEIGHT - 1);
    return field[cell_index(x, y)];
}

static float lerp(float left, float right, float amount) {
    return left + (right - left) * amount;
}

static Vec2 sample_velocity(const Vec2 *field, float x, float y) {
    x = clamp_float(x, (float)(GRID_WIDTH - 1));
    y = clamp_float(y, (float)(GRID_HEIGHT - 1));
    int base_x = (int)x;
    int base_y = (int)y;
    float fraction_x = x - (float)base_x;
    float fraction_y = y - (float)base_y;
    Vec2 value_00 = read_velocity(field, base_x, base_y);
    Vec2 value_10 = read_velocity(field, base_x + 1, base_y);
    Vec2 value_01 = read_velocity(field, base_x, base_y + 1);
    Vec2 value_11 = read_velocity(field, base_x + 1, base_y + 1);
    Vec2 result = {
        .x = lerp(
            lerp(value_00.x, value_10.x, fraction_x),
            lerp(value_01.x, value_11.x, fraction_x),
            fraction_y),
        .y = lerp(
            lerp(value_00.y, value_10.y, fraction_x),
            lerp(value_01.y, value_11.y, fraction_x),
            fraction_y),
    };
    return result;
}

static float sample_scalar(const float *field, float x, float y) {
    x = clamp_float(x, (float)(GRID_WIDTH - 1));
    y = clamp_float(y, (float)(GRID_HEIGHT - 1));
    int base_x = (int)x;
    int base_y = (int)y;
    float fraction_x = x - (float)base_x;
    float fraction_y = y - (float)base_y;
    float value_00 = read_scalar(field, base_x, base_y);
    float value_10 = read_scalar(field, base_x + 1, base_y);
    float value_01 = read_scalar(field, base_x, base_y + 1);
    float value_11 = read_scalar(field, base_x + 1, base_y + 1);
    return lerp(
        lerp(value_00, value_10, fraction_x),
        lerp(value_01, value_11, fraction_x),
        fraction_y);
}

static void seed(Vec2 *velocity, float *dye, float *pressure_a,
                 float *pressure_b) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            size_t index = cell_index(x, y);
            float uv_x = ((float)x + 0.5f) / (float)GRID_WIDTH;
            float uv_y = ((float)y + 0.5f) / (float)GRID_HEIGHT;
            float centered_x = uv_x * 2.0f - 1.0f;
            float centered_y = uv_y * 2.0f - 1.0f;
            float radius_squared =
                centered_x * centered_x + centered_y * centered_y;
            uint32_t mixed = scramble_seed(UINT32_C(1337) ^ (uint32_t)index);
            float sample = (float)(mixed & UINT32_C(0x00ffffff)) * INV_U24 -
                           0.5f;
            float vortex = FORCE_SCALE / (1.0f + 10.0f * radius_squared);
            velocity[index].x = -centered_y * vortex + sample * 0.02f;
            velocity[index].y = centered_x * vortex - sample * 0.02f;
            float source = 1.0f - 2.5f * radius_squared;
            if (source < 0.0f) {
                source = 0.0f;
            }
            dye[index] = source + (sample + 0.5f) * 0.05f;
            pressure_a[index] = 0.0f;
            pressure_b[index] = 0.0f;
        }
    }
}

static void advect_velocity(const Vec2 *input, Vec2 *output) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            size_t index = cell_index(x, y);
            Vec2 velocity = input[index];
            float backtrace_x =
                (float)x - velocity.x * TIME_STEP * 12.0f;
            float backtrace_y =
                (float)y - velocity.y * TIME_STEP * 12.0f;
            Vec2 sampled = sample_velocity(input, backtrace_x, backtrace_y);
            float centered_x =
                (((float)x + 0.5f) / (float)GRID_WIDTH) * 2.0f - 1.0f;
            float centered_y =
                (((float)y + 0.5f) / (float)GRID_HEIGHT) * 2.0f - 1.0f;
            float radius_squared =
                centered_x * centered_x + centered_y * centered_y;
            float swirl_scale = 0.08f * FORCE_SCALE /
                                (1.0f + 4.0f * radius_squared);
            output[index].x =
                sampled.x * VELOCITY_DISSIPATION - centered_y * swirl_scale;
            output[index].y =
                sampled.y * VELOCITY_DISSIPATION + centered_x * swirl_scale;
        }
    }
}

static void divergence(const Vec2 *velocity, float *output) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            Vec2 left = read_velocity(velocity, x - 1, y);
            Vec2 right = read_velocity(velocity, x + 1, y);
            Vec2 bottom = read_velocity(velocity, x, y - 1);
            Vec2 top = read_velocity(velocity, x, y + 1);
            output[cell_index(x, y)] =
                0.5f * ((right.x - left.x) + (top.y - bottom.y));
        }
    }
}

static void pressure(const float *divergence_field, const float *input,
                     float *output) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            float left = read_scalar(input, x - 1, y);
            float right = read_scalar(input, x + 1, y);
            float bottom = read_scalar(input, x, y - 1);
            float top = read_scalar(input, x, y + 1);
            output[cell_index(x, y)] =
                (left + right + bottom + top -
                 divergence_field[cell_index(x, y)]) *
                0.25f;
        }
    }
}

static void project(const Vec2 *velocity, const float *pressure_field,
                    Vec2 *output) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            size_t index = cell_index(x, y);
            float left = read_scalar(pressure_field, x - 1, y);
            float right = read_scalar(pressure_field, x + 1, y);
            float bottom = read_scalar(pressure_field, x, y - 1);
            float top = read_scalar(pressure_field, x, y + 1);
            output[index].x = velocity[index].x - (right - left) * 0.5f;
            output[index].y = velocity[index].y - (top - bottom) * 0.5f;
        }
    }
}

static void advect_dye(const float *input, const Vec2 *velocity,
                       float *output) {
    for (int y = 0; y < GRID_HEIGHT; ++y) {
        for (int x = 0; x < GRID_WIDTH; ++x) {
            size_t index = cell_index(x, y);
            float backtrace_x =
                (float)x - velocity[index].x * TIME_STEP * 12.0f;
            float backtrace_y =
                (float)y - velocity[index].y * TIME_STEP * 12.0f;
            float centered_x =
                (((float)x + 0.5f) / (float)GRID_WIDTH) * 2.0f - 1.0f;
            float centered_y =
                (((float)y + 0.5f) / (float)GRID_HEIGHT) * 2.0f - 1.0f;
            float source =
                1.0f - 8.0f *
                           (centered_x * centered_x +
                            centered_y * centered_y);
            if (source < 0.0f) {
                source = 0.0f;
            }
            output[index] =
                sample_scalar(input, backtrace_x, backtrace_y) *
                    DYE_DISSIPATION +
                source * 0.02f;
        }
    }
}

static int write_output(const char *path, const float *dye) {
    FILE *output = fopen(path, "wb");
    if (output == NULL) {
        return 1;
    }
    size_t written = fwrite(dye, sizeof(*dye), CELL_COUNT, output);
    int close_status = fclose(output);
    return written == CELL_COUNT && close_status == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <output-f32le-bin>\n", argv[0]);
        return 2;
    }
    Vec2 *velocity_a = calloc(CELL_COUNT, sizeof(*velocity_a));
    Vec2 *velocity_b = calloc(CELL_COUNT, sizeof(*velocity_b));
    float *dye_a = calloc(CELL_COUNT, sizeof(*dye_a));
    float *dye_b = calloc(CELL_COUNT, sizeof(*dye_b));
    float *divergence_field = calloc(CELL_COUNT, sizeof(*divergence_field));
    float *pressure_a = calloc(CELL_COUNT, sizeof(*pressure_a));
    float *pressure_b = calloc(CELL_COUNT, sizeof(*pressure_b));
    if (velocity_a == NULL || velocity_b == NULL || dye_a == NULL ||
        dye_b == NULL || divergence_field == NULL || pressure_a == NULL ||
        pressure_b == NULL) {
        fprintf(stderr, "stable-fluids reference allocation failed\n");
        return 1;
    }

    seed(velocity_a, dye_a, pressure_a, pressure_b);
    for (int step = 0; step < SIMULATION_STEPS; ++step) {
        advect_velocity(velocity_a, velocity_b);
        divergence(velocity_b, divergence_field);
        for (int iteration = 0; iteration < PRESSURE_PAIRS; ++iteration) {
            pressure(divergence_field, pressure_a, pressure_b);
            pressure(divergence_field, pressure_b, pressure_a);
        }
        project(velocity_b, pressure_a, velocity_a);
        advect_dye(dye_a, velocity_a, dye_b);
        float *dye_swap = dye_a;
        dye_a = dye_b;
        dye_b = dye_swap;
    }

    int status = write_output(argv[1], dye_a);
    free(velocity_a);
    free(velocity_b);
    free(dye_a);
    free(dye_b);
    free(divergence_field);
    free(pressure_a);
    free(pressure_b);
    return status;
}
