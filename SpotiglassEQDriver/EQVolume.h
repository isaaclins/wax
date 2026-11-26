#ifndef SPOTIGLASS_EQ_VOLUME_H
#define SPOTIGLASS_EQ_VOLUME_H

// The EQ device's master volume, kept apart from Core Audio so the driver
// tests run it as it is (#605).
//
// While the EQ is on, the system volume is the EQ device's volume. When the
// device the sound goes to has a settable master volume, the level is
// forwarded to it (ADR-EQ-3). Many USB DACs and HDMI / DisplayPort monitors
// have none: forwarding fails and the music used to stay at full volume while
// the slider moved. Then the driver applies the level itself, in the render
// path, with a short ramp so a change doesn't click.

#include <atomic>
#include <math.h>
#include <stdint.h>

/// The level the user set and whether the driver applies it itself.
/// `level` and `pending*` are written by SetPropertyData, `software` is read
/// by the render callback; everything else belongs to the mirror worker.
struct EQVolume {
    /// Last scalar (0..1) the OS / user set, or the target's own level while
    /// it is forwarded to.
    std::atomic<float> level{1.0f};
    /// A write SetPropertyData staged for the worker.
    std::atomic<float> pendingWrite{1.0f};
    std::atomic<bool> hasPendingWrite{false};
    /// Whether the render path applies `level` (the target can't take it).
    std::atomic<bool> software{false};

    uint32_t target = 0;  // worker only: the target the mode was decided for

    /// The scalar to multiply samples by right now.
    float renderGain() const {
        return software.load(std::memory_order_acquire)
            ? level.load(std::memory_order_acquire)
            : 1.0f;
    }

    /// SetPropertyData: the user set `scalar`.
    void userSets(float scalar) {
        scalar = clamp(scalar);
        level.store(scalar, std::memory_order_release);
        pendingWrite.store(scalar, std::memory_order_release);
        hasPendingWrite.store(true, std::memory_order_release);
    }

    /// One worker tick against the router's target. `Target` provides
    /// `uint32_t id()`, `bool settable()`, `bool set(float)` and
    /// `bool get(float&)`. Returns whether `level` changed under HAL clients
    /// (they need a PropertiesChanged).
    template <typename Target>
    bool tick(Target& t) {
        const uint32_t id = t.id();
        if (id != target) {
            target = id;
            software.store(!t.settable(), std::memory_order_release);
        }
        const bool hadWrite = hasPendingWrite.exchange(false, std::memory_order_acq_rel);
        if (software.load(std::memory_order_acquire)) return false;

        // Drain a pending write before sampling, otherwise the read races
        // the write and the slider flickers back to the stale value.
        if (hadWrite && !t.set(clamp(pendingWrite.load(std::memory_order_acquire)))) {
            software.store(true, std::memory_order_release);
            return false;
        }
        float fresh = 0.0f;
        if (!t.get(fresh)) {
            software.store(true, std::memory_order_release);
            return false;
        }
        fresh = clamp(fresh);
        if (fabsf(fresh - level.load(std::memory_order_acquire)) < 0.0005f) return false;
        level.store(fresh, std::memory_order_release);
        return true;
    }

    static float clamp(float s) { return s < 0.0f ? 0.0f : (s > 1.0f ? 1.0f : s); }
};

/// The render path's gain. Moves toward the wanted gain by at most a full
/// swing per kRampSeconds, so a volume change is a short fade, not a click.
/// Render thread only.
struct EQGainRamp {
    static constexpr float kRampSeconds = 0.01f;

    float gain = 1.0f;
    bool primed = false;

    /// IO (re)starts: the first buffer starts at the wanted gain, so playback
    /// never begins with a fade down from full volume.
    void reset() { primed = false; }

    /// Multiplies `frames` interleaved stereo frames by the ramped gain.
    void apply(float* samples, uint32_t frames, float wanted, uint32_t sampleRate) {
        if (!primed) {
            gain = wanted;
            primed = true;
        }
        if (gain == 1.0f && wanted == 1.0f) return;
        const float rate = sampleRate > 0 ? static_cast<float>(sampleRate) : 48000.0f;
        const float step = 1.0f / (kRampSeconds * rate);
        for (uint32_t i = 0; i < frames; ++i) {
            const float delta = wanted - gain;
            if (delta > step) gain += step;
            else if (delta < -step) gain -= step;
            else gain = wanted;
            samples[2 * i] *= gain;
            samples[2 * i + 1] *= gain;
        }
    }
};

#endif
