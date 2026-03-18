#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <MiniFB.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#define WIDTH 512
#define VISUALIZER_HEIGHT 256
#define TAB_HEIGHT 10
#define TOTAL_HEIGHT (VISUALIZER_HEIGHT + TAB_HEIGHT)

// Global buffer to hold our audio samples
// 512 samples at 44.1kHz = ~11.6ms of audio. 
// A 200Hz wave takes 5ms per cycle, so this perfectly fits ~2 full waves on screen!
float wave_buffer[WIDTH] = {0};

// State machine for tabs
typedef enum {
    TAB_VISUALIZER,
    TAB_AMP_CONFIG
} AppTab;

// Miniaudio callback: This runs automatically in the background to grab sound
void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pDevice; (void)pOutput; // Unused in capture mode
    const float* pInputF32 = (const float*)pInput;
    
    // Shift old data to the left, copy new data to the right (scrolling oscilloscope)
    int shift = frameCount;
    if (shift > WIDTH) shift = WIDTH;
    
    memmove(wave_buffer, wave_buffer + shift, (WIDTH - shift) * sizeof(float));
    memcpy(wave_buffer + (WIDTH - shift), pInputF32, shift * sizeof(float));
}

// Minimal function to draw a connected line so the sine wave doesn't look like dots
void draw_line(uint32_t* buffer, int x0, int y0, int x1, int y1, uint32_t color) {
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1; 
    int err = dx + dy, e2; /* error value e_xy */

    while (1) {
        if (x0 >= 0 && x0 < WIDTH && y0 >= 0 && y0 < TOTAL_HEIGHT) {
            buffer[y0 * WIDTH + x0] = color;
        }
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

int main() {
    // 1. Setup Audio Capture
    ma_device_config deviceConfig = ma_device_config_init(ma_device_type_capture);
    deviceConfig.capture.format   = ma_format_f32;
    deviceConfig.capture.channels = 1; // Mono
    deviceConfig.sampleRate       = 44100;
    deviceConfig.dataCallback     = data_callback;

    ma_device device;
    if (ma_device_init(NULL, &deviceConfig, &device) != MA_SUCCESS) {
        printf("Failed to initialize capture device.\n");
        return -1;
    }
    ma_device_start(&device);

    // 2. Setup MiniFB Window
    struct mfb_window *window = mfb_open_ex("Amp Interface", WIDTH, TOTAL_HEIGHT, WF_RESIZABLE);
    uint32_t *buffer = (uint32_t *)malloc(WIDTH * TOTAL_HEIGHT * 4);
    
    AppTab current_tab = TAB_VISUALIZER;
    struct mfb_timer *timer = mfb_timer_create();

    // 200Hz target frame time
    double ns_per_frame = 1000000000.0 / 200.0; 

    while (1) {
        mfb_timer_reset(timer);
        memset(buffer, 0, WIDTH * TOTAL_HEIGHT * 4); // Clear screen to black

        // --- INPUT HANDLING ---
        const mfb_mouse_button_status *mouse = mfb_get_mouse_button_status(window);
        if (mouse[MOUSE_LEFT]) {
            int mx = mfb_get_mouse_x(window);
            int my = mfb_get_mouse_y(window);
            
            // Check if clicking in the top 10 pixels
            if (my <= TAB_HEIGHT) {
                if (mx < WIDTH / 2) current_tab = TAB_VISUALIZER;
                else current_tab = TAB_AMP_CONFIG;
            }
        }

        // --- DRAW UI ---
        // Draw Tab Bar Backgrounds
        uint32_t vis_color = (current_tab == TAB_VISUALIZER) ? MFB_RGB(50, 50, 50) : MFB_RGB(20, 20, 20);
        uint32_t amp_color = (current_tab == TAB_AMP_CONFIG) ? MFB_RGB(50, 50, 50) : MFB_RGB(20, 20, 20);
        
        for (int y = 0; y < TAB_HEIGHT; y++) {
            for (int x = 0; x < WIDTH / 2; x++) buffer[y * WIDTH + x] = vis_color;
            for (int x = WIDTH / 2; x < WIDTH; x++) buffer[y * WIDTH + x] = amp_color;
        }

        // --- DRAW ACTIVE TAB ---
        if (current_tab == TAB_VISUALIZER) {
            // Draw Oscilloscope
            int center_y = TAB_HEIGHT + (VISUALIZER_HEIGHT / 2);
            for (int x = 0; x < WIDTH - 1; x++) {
                // Amplify the float value (-1.0 to 1.0) to fit the screen height
                int y0 = center_y - (int)(wave_buffer[x] * (VISUALIZER_HEIGHT / 2));
                int y1 = center_y - (int)(wave_buffer[x+1] * (VISUALIZER_HEIGHT / 2));
                
                draw_line(buffer, x, y0, x + 1, y1, MFB_RGB(0, 255, 100)); // Neon Green
            }
        } else if (current_tab == TAB_AMP_CONFIG) {
            // Placeholder for Amp controls
            // draw_line(buffer, 256, 128, 256, 128, MFB_RGB(255, 255, 255));
        }

        // --- UPDATE & SYNC ---
        short state = mfb_update_ex(window, buffer, WIDTH, TOTAL_HEIGHT);
        if (state < 0) break; // Window closed

        // Force 200Hz loop
        while (mfb_timer_now(timer) < ns_per_frame / 1000000000.0) {}
    }

    ma_device_uninit(&device);
    free(buffer);
    return 0;
}