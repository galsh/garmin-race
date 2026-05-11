import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.UserProfile;
import Toybox.WatchUi;

class gavsRacePacerView extends WatchUi.DataField {

    // --- settings-derived state (recomputed in loadSettings) ---
    private var mTargetPaceSecs as Number = 360;   // overall average target (sec/km)
    private var mRaceDistanceM as Number = 10000;  // race distance in metres
    private var mLapTargetPaces as Array<Number>?  = null; // per-km targets, index = km number
    private var mHrZones as Array<Number>? = null;

    // --- live sensor state (updated in compute) ---
    private var mSpeedBuf as Array<Float> = [0.0f, 0.0f, 0.0f, 0.0f, 0.0f];
    private var mSpeedIdx as Number = 0;
    private var mCurrentPaceSecs as Number = 0;
    private var mLapPaceSecs as Number = 0;
    private var mElapsedMs as Number = 0;
    private var mDistanceM as Float = 0.0f;
    private var mLastLapCount as Number = 0;
    private var mLapStartDistanceM as Float = 0.0f;
    private var mLapStartTimeMs as Number = 0;
    private var mHeartRate as Number = 0;
    private var mCurrentLapTargetSecs as Number = 360; // target for the km we're currently in
    private var mWorkoutTargetPaceLow  as Number = 0;  // fast end (sec/km) from workout step; 0 = none
    private var mStepIsRun             as Boolean = true;
    private var mStepDurationM         as Float   = 0.0f; // step target distance (m), 0 if not distance-based
    private var mPrevStepIsRun         as Boolean = true;
    private var mRunStartMs            as Number  = 0;
    private var mRunStartDistM         as Float   = 0.0f;
    private var mRunTotalMs            as Number  = 0;
    private var mRunTotalDistM         as Float   = 0.0f;

    function initialize() {
        DataField.initialize();
        loadSettings();
    }

    function loadSettings() as Void {
        var v;

        v = Application.Properties.getValue("targetPace");
        if (v instanceof Number && (v as Number) > 0) { mTargetPaceSecs = v as Number; }

        v = Application.Properties.getValue("raceDistance");
        if (v instanceof Number && (v as Number) > 0) { mRaceDistanceM = v as Number; }

        mHrZones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_GENERIC);
        mLapTargetPaces = computeLapPaces();
        mCurrentLapTargetSecs = lapTarget(0);
    }

    // -----------------------------------------------------------------------
    // Pacing maths
    // -----------------------------------------------------------------------

    private function computeLapPaces() as Array<Number> {
        var numLaps = mRaceDistanceM / 1000 + 2;
        var paces = [] as Array<Number>;
        for (var i = 0; i < numLaps; i++) { paces.add(mTargetPaceSecs); }
        return paces;
    }

    // Target pace (sec/km) for lap index k.
    private function lapTarget(k as Number) as Number {
        var laps = mLapTargetPaces;
        if (laps == null || laps.size() == 0) { return mTargetPaceSecs; }
        var idx = (k < laps.size()) ? k : (laps.size() - 1);
        return laps[idx] as Number;
    }

    // Cumulative expected finish time (seconds) for the given distance.
    // Accounts for variable per-km pacing.
    private function targetTimeForDist(distKm as Float) as Float {
        var fullLaps = distKm.toNumber();
        var partial  = distKm - fullLaps.toFloat();
        var laps     = mLapTargetPaces;
        if (laps == null) { return mTargetPaceSecs.toFloat() * distKm; }
        var maxIdx   = laps.size() - 1;
        var total    = 0.0f;
        var limit    = (fullLaps <= maxIdx) ? fullLaps : (maxIdx + 1);
        for (var i = 0; i < limit; i++) { total += (laps[i] as Number).toFloat(); }
        if (partial > 0.001f) {
            var li = (fullLaps < laps.size()) ? fullLaps : maxIdx;
            total += partial * (laps[li] as Number).toFloat();
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Data field callbacks
    // -----------------------------------------------------------------------

    function onLayout(dc as Graphics.Dc) as Void {}

    function compute(info as Activity.Info) as Void {
        if ((info has :currentSpeed) && info.currentSpeed != null && (info.currentSpeed as Float) > 0.1f) {
            mSpeedBuf[mSpeedIdx] = info.currentSpeed as Float;
            mSpeedIdx = (mSpeedIdx + 1) % 5;
            var sum = 0.0f;
            var count = 0;
            for (var i = 0; i < 5; i++) {
                if ((mSpeedBuf[i] as Float) > 0.1f) { sum += mSpeedBuf[i] as Float; count++; }
            }
            mCurrentPaceSecs = (count > 0) ? garminRoundPace((1000.0f / (sum / count) + 0.5f).toNumber()) : 0;
        } else { mCurrentPaceSecs = 0; }

        if ((info has :elapsedTime)    && info.elapsedTime    != null) { mElapsedMs  = info.elapsedTime    as Number; }
        if ((info has :elapsedDistance)&& info.elapsedDistance!= null) { mDistanceM  = info.elapsedDistance as Float;  }
        if ((info has :currentHeartRate)&&info.currentHeartRate!=null) { mHeartRate  = info.currentHeartRate as Number;}

        var lapCount = ((info has :lapCount) && info.lapCount != null) ? (info.lapCount as Number) : 0;
        if (lapCount != mLastLapCount) {
            mLastLapCount = lapCount;
            mLapStartDistanceM = mDistanceM;
            mLapStartTimeMs = mElapsedMs;
        }
        var lapDist = mDistanceM - mLapStartDistanceM;
        var lapTime = mElapsedMs - mLapStartTimeMs;
        if (lapDist > 10.0f && lapTime > 0) {
            mLapPaceSecs = (lapTime.toFloat() / lapDist + 0.5f).toNumber();
        } else { mLapPaceSecs = 0; }

        mWorkoutTargetPaceLow = 0;
        mStepIsRun = true;
        mStepDurationM = 0.0f;
        try {
            var stepInfo = Activity.getCurrentWorkoutStep();
            if (stepInfo != null) {
                var step = stepInfo.step;
                if (step instanceof Activity.WorkoutIntervalStep) {
                    step = (step as Activity.WorkoutIntervalStep).activeStep;
                }
                mStepIsRun = (stepInfo.intensity == Activity.WORKOUT_INTENSITY_ACTIVE);
                if (step instanceof Activity.WorkoutStep) {
                    var ws = step as Activity.WorkoutStep;
                    if (ws.durationType == Activity.WORKOUT_STEP_DURATION_DISTANCE && ws.durationValue != null) {
                        mStepDurationM = ws.durationValue as Float;
                    }
                    if (ws.targetType == Activity.WORKOUT_STEP_TARGET_SPEED &&
                            ws.targetValueLow != null && ws.targetValueHigh != null) {
                        var loF = ws.targetValueLow as Float;
                        var hiF = ws.targetValueHigh as Float;
                        if (loF > 0.001f && hiF > 0.001f) {
                            mWorkoutTargetPaceLow = garminRoundPace((1000.0f / hiF + 0.5f).toNumber());
                            mCurrentLapTargetSecs = ((1000.0f / loF + 1000.0f / hiF) / 2.0f + 0.5f).toNumber();
                        }
                    }
                }
            }
        } catch (e instanceof Lang.Exception) {}

        if (mWorkoutTargetPaceLow == 0) {
            mCurrentLapTargetSecs = lapTarget((mDistanceM / 1000.0f).toNumber());
        }

        if (mStepIsRun != mPrevStepIsRun) {
            if (mStepIsRun) {
                mRunStartMs    = mElapsedMs;
                mRunStartDistM = mDistanceM;
            } else {
                mRunTotalMs    += mElapsedMs - mRunStartMs;
                mRunTotalDistM += mDistanceM - mRunStartDistM;
            }
            mPrevStepIsRun = mStepIsRun;
        }
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

        dc.setColor(bg, bg);
        dc.clear();

        var r1h = h * 20 / 100;
        var r2h = h * 30 / 100;
        var r3h = h * 30 / 100;
        var r4h = h - r1h - r2h - r3h;
        var r2y = r1h;
        var r3y = r1h + r2h;
        var r4y = r1h + r2h + r3h;

        drawRow1(dc, 0,   r1h, w, fg);
        drawRow2(dc, r2y, r2h, w);
        drawRow3(dc, r3y, r3h, w, fg);
        drawRow4(dc, r4y, r4h, w);

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(0, r1h, w, r1h);
        dc.drawLine(0, r3y, w, r3y);
        dc.drawLine(0, r4y, w, r4y);
    }

    // Row 1 — workout step range when active, otherwise app-settings target
    private function drawRow1(dc as Graphics.Dc, y as Number, h as Number, w as Number, fg as Number) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var s = "TGT " + fmtPace(mCurrentLapTargetSecs);
        boldText(dc, w / 2, y + h / 2, Graphics.FONT_SMALL, s,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Row 2 — PACE | LAP | AHEAD/BEHIND, all colour-coded
    private function drawRow2(dc as Graphics.Dc, y as Number, h as Number, w as Number) as Void {
        var colW     = w / 3;
        var lFont    = Graphics.FONT_XTINY;
        var vFont    = pickFitFont(dc, "10:00", colW * 9 / 10, true);
        var lH       = dc.getFontHeight(lFont);
        var vH       = dc.getFontHeight(vFont);
        var gap      = -3;
        var gTop     = y + (h - lH - gap - vH) / 2;
        var lY       = gTop + lH / 2;
        var vY       = gTop + lH + gap + vH / 2;
        // LAP
        dc.setColor(paceZoneColor(mLapPaceSecs, mCurrentLapTargetSecs), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, colW, h);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(colW / 2, lY, lFont, "LAP", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        boldText(dc, colW / 2, vY, vFont,
            (mLapPaceSecs > 0) ? fmtPace(mLapPaceSecs) : "--:--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // PACE
        dc.setColor(paceZoneColor(mCurrentPaceSecs, mCurrentLapTargetSecs), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(colW, y, colW, h);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(colW + colW / 2, lY, lFont, "PACE", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        boldText(dc, colW + colW / 2, vY, vFont,
            (mCurrentPaceSecs > 0) ? fmtPace(mCurrentPaceSecs) : "--:--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // AHEAD / BEHIND (run step) or REMAINING segment distance (non-run step)
        if (mStepIsRun) {
            var delta   = computeDelta();
            var isAhead = (delta >= 0);
            dc.setColor(isAhead ? Graphics.COLOR_GREEN : Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(colW * 2, y, colW, h);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colW * 2 + colW / 2, lY, lFont,
                isAhead ? "AHEAD" : "BEHIND",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            boldText(dc, colW * 2 + colW / 2, vY, vFont,
                fmtSecs(isAhead ? delta : -delta),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            var lapDist  = mDistanceM - mLapStartDistanceM;
            var remainM  = mStepDurationM - lapDist;
            var remainKm = (mStepDurationM > 0.0f && remainM >= 0.0f) ? remainM / 1000.0f : -1.0f;
            dc.setColor(0x9B9EA2, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(colW * 2, y, colW, h);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colW * 2 + colW / 2, lY, lFont, "REMAIN",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            boldText(dc, colW * 2 + colW / 2, vY, vFont,
                (remainKm >= 0.0f) ? remainKm.format("%.2f") : "--",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(colW,     y, colW,     y + h);
        dc.drawLine(colW * 2, y, colW * 2, y + h);
    }

    // Row 3 — TIMER | DIST
    private function drawRow3(dc as Graphics.Dc, y as Number, h as Number, w as Number, fg as Number) as Void {
        var colW  = w / 2;
        var lFont = Graphics.FONT_XTINY;
        var vFont = pickFitFont(dc, fmtTime(mElapsedMs), colW * 9 / 10, true);
        var lH    = dc.getFontHeight(lFont);
        var vH    = dc.getFontHeight(vFont);
        var gap   = -3;
        var gTop  = y + (h - vH - gap - lH) / 2;
        var vY    = gTop + vH / 2;
        var lY    = gTop + vH + gap + lH / 2;

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        boldText(dc, colW / 2, vY, vFont, fmtTime(mElapsedMs),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(colW / 2, lY, lFont, "TIMER",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        boldText(dc, colW + colW / 2, vY, vFont, (mDistanceM / 1000.0f).format("%.2f"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(colW + colW / 2, lY, lFont, "DIST",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(colW, y, colW, y + h);
    }

    // Row 4 — HR with Garmin zone colour
    private function drawRow4(dc as Graphics.Dc, y as Number, h as Number, w as Number) as Void {
        dc.setColor(hrZoneColor(mHeartRate), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, y, w, h);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        boldText(dc, w / 2, y + h / 2, Graphics.FONT_SMALL,
            (mHeartRate > 0) ? ("HR " + mHeartRate.toString()) : "HR --",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private function computeDelta() as Number {
        var runMs     = mRunTotalMs + (mElapsedMs - mRunStartMs);
        var runDistKm = (mRunTotalDistM + (mDistanceM - mRunStartDistM)) / 1000.0f;
        var expected  = (mWorkoutTargetPaceLow > 0)
            ? mCurrentLapTargetSecs.toFloat() * runDistKm
            : targetTimeForDist(runDistKm);
        return (expected - (runMs / 1000).toFloat()).toNumber();
    }

    // Colour for PACE / LAP columns relative to target.
    private function paceZoneColor(paceSecs as Number, targetSecs as Number) as Graphics.ColorType {
        if (paceSecs == 0 || targetSecs == 0) { return 0x00B050; }
        var diff = paceSecs - targetSecs;
        if (diff > 15 || diff < -30) { return 0xFF8C00; } // orange: way off
        if (diff < -15)              { return 0x1E90FF; } // blue: slightly faster
        return 0x00B050;                                   // green: on pace
    }

    private function hrZoneColor(hr as Number) as Number {
        if (hr <= 0) { return 0x9B9EA2; }
        var z = mHrZones;
        if (z == null || z.size() < 5) { return 0x36B37E; }
        if (hr < (z[1] as Number)) { return 0x9B9EA2; }
        if (hr < (z[2] as Number)) { return 0x5BC8F5; }
        if (hr < (z[3] as Number)) { return 0x36B37E; }
        if (hr < (z[4] as Number)) { return 0xFF9F00; }
        return 0xFF3333;
    }

    private function boldText(dc as Graphics.Dc, x as Number, y as Number, font as Graphics.FontType, text as String, justify as Number) as Void {
        dc.drawText(x,     y, font, text, justify);
        dc.drawText(x + 1, y, font, text, justify);
        dc.drawText(x + 2, y, font, text, justify);
    }

    private function pickFitFont(dc as Graphics.Dc, text as String, maxW as Number, isNumber as Boolean) as Graphics.FontType {
        var fonts = isNumber
            ? [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MILD, Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]
            : [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY];
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i] as Graphics.FontType) <= maxW) {
                return fonts[i] as Graphics.FontType;
            }
        }
        return Graphics.FONT_TINY;
    }

    // Replicates Garmin's pace rounding: remainder 1-2 rounds down, 3-4 rounds up.
    private function garminRoundPace(secsPerKm as Number) as Number {
        if (secsPerKm <= 0) { return secsPerKm; }
        return ((secsPerKm + 2) / 5) * 5;
    }

    private function fmtPace(secsPerKm as Number) as String {
        if (secsPerKm <= 0) { return "--:--"; }
        return (secsPerKm / 60).toString() + ":" + (secsPerKm % 60).format("%02d");
    }

    private function fmtTime(ms as Number) as String {
        var totalS = ms / 1000;
        var m = totalS / 60;
        var s = totalS % 60;
        if (m >= 60) {
            var hrs = m / 60;
            m = m % 60;
            return hrs.toString() + ":" + m.format("%02d") + ":" + s.format("%02d");
        }
        return m.toString() + ":" + s.format("%02d");
    }

    private function fmtSecs(secs as Number) as String {
        return (secs / 60).toString() + ":" + (secs % 60).format("%02d");
    }

}
