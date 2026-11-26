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
//
// The slider maps to dB in a straight line over kMinDB...kMaxDB, the way
// devices with their own volume do it (the Mac mini's speakers: 0.5 is
// -31.8 dB, 0.25 is -47.6 dB), so the same slider position sounds about as
// loud on a DAC as on speakers. The device's reported dB uses the same curve.

#include <atomic>
#include <math.h>
#include <stdint.h>

/// The level the user set and whether the driver applies it itself.
/// `level` and `pending*` are written by SetPropertyData, `software` is read
/// by the render callback; everything else belongs to the mirror worker.
struct EQVolume {
    static constexpr float kMinDB = -64.0f;
    static constexpr float kMaxDB = 0.0f;

    /// Slider (0..1) to dB: a straight line from kMinDB to kMaxDB. 0 reports
    /// the floor rather than -inf so HAL clients don't see a denormal.
    static float scalarToDB(float scalar) {
        scalar = clamp(scalar);
        return kMinDB + (kMaxDB - kMinDB) * scalar;
    }

    /// Inverse of scalarToDB, clamped to [0, 1].
    static float dbToScalar(float db) {
        return clamp((db - kMinDB) / (kMaxDB - kMinDB));
    }

    /// The amplitude the render path multiplies by for a slider value. 0 is
    /// silence, not the -64 dB floor.
    static float amplitude(float scalar) {
        scalar = clamp(scalar);
        if (scalar <= 0.0f) return 0.0f;
        if (scalar >= 1.0f) return 1.0f;
        return powf(10.0f, scalarToDB(scalar) / 20.0f);
    }

    /// Last scalar (0..1) the OS / user set, or the target's own level while
    /// it is forwarded to.
    std::atomic<float> level{1.0f};
    /// A write SetPropertyData staged for the worker.
    std::atomic<float> pendingWrite{1.0f};
    std::atomic<bool> hasPendingWrite{false};
    /// Whether the render path applies `level` (the target can't take it).
    std::atomic<bool> software{false};
    /// The target `software` was decided for. Written by the worker, read by
    /// the render callback.
    std::atomic<uint32_t> decidedTarget{0};

    /// The amplitude to multiply samples by right now, for the router's
    /// current target. Until the worker has decided the mode for that target
    /// (up to one tick after the router moved), the level applies in
    /// software: a DAC without a volume must not get a burst at full scale,
    /// and a device that takes the volume is at worst briefly quieter.
    float renderGain(uint32_t currentTarget) const {
        const bool decided = decidedTarget.load(std::memory_order_acquire) == currentTarget;
        if (decided && !software.load(std::memory_order_acquire)) return 1.0f;
        return amplitude(level.load(std::memory_order_acquire));
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
        if (id != decidedTarget.load(std::memory_order_acquire)) {
            software.store(!t.settable(), std::memory_order_release);
            decidedTarget.store(id, std::memory_order_release);
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
