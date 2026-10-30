if not A_IsAdmin {
    Run *RunAs "%A_AhkPath%" "%A_ScriptFullPath%"
    ExitApp
}

#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
SendMode Event
SetBatchLines -1
SetKeyDelay, -1, -1
CoordMode, Mouse, Screen
CoordMode, Pixel, Screen
DllCall("SetProcessDPIAware")
DllCall("winmm\timeBeginPeriod", "UInt", 1)

; =====================================================================
; НАСТРОЙКИ
; =====================================================================
; --- Геометрия колец. Измерено по двум скриншотам при 1080p:
;     диаметр зелёного кольца бывает разный (263 px и 225 px), а толщина полос одна и та же:
;     тёмно-зелёная полоса: от (внешний радиус - 24.5) до (внешний радиус - 9.5) px, ширина 15 px;
;     яркая внешняя кайма: 10 px; белая линия: около 5 px, на 1-м кадре внутри кольца, на 2-м снаружи.
;     Внешний радиус кольца скрипт измеряет на экране сам; смещения полосы заданы в px при 1080p
;     и умножаются на Scl = высота экрана / 1080 (для других разрешений НЕ проверено).
global RefDiam      := 263      ; ориентир диаметра, только для грубой проверки размера при поиске (допустимо 0.4..2.0 от него)
; --- ЦЕЛЬ нажатия (расстояние от внешнего радиуса кольца, px при 1080p, внутрь = плюс).
;     Тёмно-зелёная полоса (по умолчанию). Подтверждено на трёх кольцах D=263, 225, 185: геометрия полосы одна и та же.
;     (светло-зелёная внешняя кайма была бы: TargetInOff = 9.5, TargetOutOff = -0.5)
global TargetInOff  := 8.0      ; ЦЕЛЬ = самое яркое ядро светло-зелёной каймы (измерено: r 77.5..83.5 при внешнем 85.5)
global TargetOutOff := 2.0      ; внешний край ядра
global ScanMinK     := 0.25     ; где искать белое кольцо: от этой доли радиуса...
global ScanMaxK     := 1.75     ; ...до этой (по журналу линия стартует снаружи, до ~1.65 радиуса зелёного кольца)
global NRays        := 40       ; число лучей для измерения радиуса белого кольца

; --- Цвета (допуски). Зелёное кольцо полупрозрачное, поэтому ищем по насыщенности, а не по точному цвету.
global GreenGMin    := 135      ; G не меньше
global GreenRG      := 100      ; G - R не меньше
global GreenBG      := 55       ; G - B не меньше
global LineRMin     := 105      ; линия: белая снаружи/внутри кольца и бледно-зелёная под зелёным кольцом
global LineGMin     := 200      ; (по журналу игры под кольцом она не белая). Зелёное кольцо само: R не выше ~85,
global LineBMin     := 140      ; поэтому R >= 150 надёжно отделяет линию от него. Цвет под кольцом ОЦЕНЁН, не измерен

; --- Момент нажатия
global PressFracMin := 0.30     ; в какой доле ширины полосы (от входного края) нажимать: случайно между Min и Max
global PressFracMax := 0.70
global PressLatencyMs := 90     ; на сколько мс вперёд предсказывать положение кольца. 30 = поздно, 120 = рано, 75 = ещё чуть рано/поздно по отзыву
global MinSpeedK    := 0.15     ; скорость кольца меньше этой доли радиуса в секунду = кольцо стоит
global MinRepeatMs  := 600      ; минимум мс между двумя нажатиями
global RearmGapK    := 0.05     ; после нажатия: ждём, пока кольцо уйдёт от полосы на эту долю радиуса

; --- Клавиша
global KeyDown      := "{sc039 down}"   ; Space (scancode)
global KeyUp        := "{sc039 up}"
global KeyHoldMin   := 35       ; мс удержания клавиши
global KeyHoldMax   := 80

; --- РЕЖИМ выбирается клавишами: F4 = ЭСПАНДЕР, F5 = КАЧАЛКА (пока скрипт не запущен), запоминается в kachalka.ini
; --- ЭСПАНДЕР: кружок -> Space; если кружка нет дольше 7 с (кд между подходами 7 с) - жмём Z заново
global ExpIdleMs    := 7500     ; колец нет столько мс (кд 7 с + запас) => жмём Z ещё раз
global KeyZ_Down    := "{sc02C down}"   ; Z (скан-код, не зависит от раскладки)
global KeyZ_Up      := "{sc02C up}"
global ScriptMode   := "GYM"    ; GYM = качалка, EXP = эспандер (меняется F4/F5)

; --- КАЧАЛКА: кружок -> Space (кд между кружками 2.5 с). Циклы закончились -> кд 30 с -> E -> качалка заново.
;     Если после E за 5 с кружка нет: F1, клик в центр экрана, скрипт останавливается.
global GymCooldownMs := 30000   ; колец нет столько мс (отсчёт от последнего кружка) => кд закончился, жмём E
global KeyE_Down    := "{sc012 down}"   ; E (скан-код)
global KeyE_Up      := "{sc012 up}"
global PostEWaitMs  := 5000      ; после E: если за столько мс не появилось кольцо - жмём F1 и кликаем
global KeyF1_Down   := "{sc03B down}"   ; F1
global KeyF1_Up     := "{sc03B up}"
global ClickX       := 0        ; куда кликать после F1 (экранные координаты). 0,0 = центр экрана
global ClickY       := 0
global ClickDelayMs := 500      ; пауза между F1 и кликом

; --- Журнал для диагностики (ничего не меняет в работе): пишет в kachalka_trace.txt, что скрипт видит в каждом кадре
global TraceOn      := true
global TraceMax     := 4000     ; максимум строк за один запуск F6

; --- Поиск / потеря кольца
global SearchSleepMs := 60      ; пауза между попытками найти кольцо
global LostMs       := 300      ; кольца нет столько мс => считаем, что мини-игра закрыта, ищем заново
global GreenLostMin := 8        ; из 16 контрольных точек зелёного кольца должно совпасть не меньше
global LoopSleepMs  := 2        ; пауза в цикле слежения

; --- Область поиска зелёного кольца (по умолчанию центральная часть экрана; задаётся F9 и пишется в kachalka.ini)
global RX := Round(A_ScreenWidth  * 0.25)
global RY := Round(A_ScreenHeight * 0.12)
global RW := Round(A_ScreenWidth  * 0.50)
global RH := Round(A_ScreenHeight * 0.76)

global Scl := A_ScreenHeight / 1080
global Running := false
global Busy := false
global RegionStep := 0
global RegX1 := 0
global RegY1 := 0
global Presses := 0
global TraceN := 0
global TraceT0 := 0
global RayC := []
global RayS := []

IniRead, rectStr, %A_ScriptDir%\kachalka.ini, Region, Rect, ERROR
if (rectStr != "ERROR") {
    StringSplit, rc, rectStr, `,
    if (rc0 = 4 && rc3 > 150 && rc4 > 150) {
        RX := rc1 + 0
        RY := rc2 + 0
        RW := rc3 + 0
        RH := rc4 + 0
    }
}

IniRead, modeStr, %A_ScriptDir%\kachalka.ini, Mode, Value, GYM
if (modeStr = "EXP" || modeStr = "GYM")
    ScriptMode := modeStr

Loop, %NRays% {
    ang := 6.28318530717958 * (A_Index - 1) / NRays
    RayC[A_Index] := Cos(ang)
    RayS[A_Index] := Sin(ang)
}

Gui, St:+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
Gui, St:Color, 000000
Gui, St:Font, s16 bold, Arial
Gui, St:Add, Text, vStTxt cLime w1100, READY [%ScriptMode%]: F4 expander | F5 gym | F6 start | F7 exit | F8 scan | F9 region
Gui, St:Show, x20 y20 NoActivate
WinSet, Transparent, 210

OnError("ShowErr")
return

ShowErr(e) {
    global Running, Busy
    Running := false
    Busy := false
    Status("ERROR line " . e.Line . ": " . e.Message . " " . e.Extra)
    return true
}

SetMode(m) {
    global ScriptMode, Running, Busy
    if (Running || Busy) {
        Status("Stop first (F6), then change mode")
        return
    }
    ScriptMode := m
    IniWrite, %m%, %A_ScriptDir%\kachalka.ini, Mode, Value
    Status("MODE: " . (m = "EXP" ? "EXPANDER" : "GYM") . "  (F6 = start)")
}

Status(txt) {
    GuiControl, St:, StTxt, %txt%
    Sleep, 1
}

; =====================================================================
; ГОРЯЧИЕ КЛАВИШИ
; =====================================================================
F6::
    if (Running) {
        Running := false
        Status("STOPPING...")
    } else if (!Busy) {
        Running := true
        Status("RUNNING [" . ScriptMode . "] (F6 = stop)")
        SetTimer, DoWork, -10
    }
return

F4::
    SetMode("EXP")
return

F5::
    SetMode("GYM")
return

F7::ExitApp

F8::
    DebugScan()
return

F9::
    MouseGetPos, mx, my
    if (!RegionStep) {
        RegX1 := mx
        RegY1 := my
        RegionStep := 1
        Status("REGION: corner 1 = " . mx . "," . my . "  -> move to bottom-right, press F9")
    } else {
        RX := Min(RegX1, mx)
        RY := Min(RegY1, my)
        RW := Abs(mx - RegX1)
        RH := Abs(my - RegY1)
        RegionStep := 0
        IniWrite, %RX%`,%RY%`,%RW%`,%RH%, %A_ScriptDir%\kachalka.ini, Region, Rect
        Status("REGION saved: " . RX . "," . RY . " " . RW . "x" . RH)
    }
return

DoWork:
    Busy := true
    FileDelete, %A_ScriptDir%\kachalka_trace.txt
    TraceN := 0
    TraceT0 := Now()
    resWork := Kachalka()
    Busy := false
    Running := false
    Status("STOPPED (presses: " . Presses . ")")
return

; =====================================================================
; ГЛАВНЫЙ ЦИКЛ
; =====================================================================
Kachalka() {
    global Running, RayC, RayS, NRays
    global TargetInOff, TargetOutOff, Scl, PressFracMin, PressFracMax, PressLatencyMs, MinSpeedK, MinRepeatMs, RearmGapK
    global SearchSleepMs, LostMs, GreenLostMin, LoopSleepMs, ScanMaxK, Presses, TargetInOff, TargetOutOff, TraceOn, TraceN, TraceMax
    global ScriptMode, ExpIdleMs, KeyZ_Down, KeyZ_Up, GymCooldownMs, KeyE_Down, KeyE_Up, PostEWaitMs, KeyF1_Down, KeyF1_Up, ClickX, ClickY, ClickDelayMs

    tracking := false
    armed := true
    pf := 0.5
    cx := 0
    cy := 0
    Ro := 0
    haveR := false
    nS := 0
    pR := 0
    pT := 0
    v := 0
    lastSeen := 0
    pressT := -100000
    lastStat := 0
    rr := 0
    mode := "GYM"
    lastRingT := Now()
    eStart := 0

    Status((ScriptMode = "EXP" ? "ЭСПАНДЕР" : "КАЧАЛКА") . ": ищу кружок (F6 = стоп)")

    Loop {
        if (!Running)
            return "stopped"

        tNow := Now()

        if (!tracking) {
            if (!FindRing(cx, cy, Ro)) {
                idle := tNow - lastRingT
                if (ScriptMode = "EXP") {
                    if (idle > ExpIdleMs) {
                        PressSc(KeyZ_Down, KeyZ_Up)
                        lastRingT := tNow
                        Trace("no ring for " . ExpIdleMs . " ms -> Z")
                        Status("EXPANDER: Z pressed (no ring)")
                    }
                } else if (mode = "GYM") {
                    if (idle >= GymCooldownMs) {
                        PressSc(KeyE_Down, KeyE_Up)
                        mode := "POSTE"
                        eStart := tNow
                        Trace("cooldown over -> E")
                        Status("E pressed, waiting for ring")
                    } else if (idle > 4500)
                        Status("GYM: cooldown, E in " . Round((GymCooldownMs - idle) / 1000) . " s")
                } else if (mode = "POSTE") {
                    if (tNow - eStart > PostEWaitMs) {
                        PressSc(KeyF1_Down, KeyF1_Up)
                        Sleep, % ClickDelayMs
                        ClickPoint(ClickX, ClickY)
                        Trace("no ring after E -> F1 + click at centre, script finished")
                        Status("F1 + click done - finished")
                        return "done"
                    }
                }
                Sleep, % SearchSleepMs
                continue
            }
            lastRingT := tNow
            if (mode = "POSTE")
                mode := "GYM"
            tracking := true
            armed := true
            pf := RandF(PressFracMin, PressFracMax)
            haveR := false
            nS := 0
            v := 0
            lastSeen := tNow
            Status("RING FOUND D=" . Round(2 * Ro + 1) . "px (F6 = stop)")
            Trace("FOUND centre=" . Round(cx, 1) . "," . Round(cy, 1) . " Ro=" . Round(Ro, 1))
        }

        cxi := Round(cx)
        cyi := Round(cy)
        half := Ceil(ScanMaxK * Ro) + 2
        S := 2 * half + 1
        lcx := half + (cx - cxi)
        lcy := half + (cy - cyi)
        hbm := CaptureDIB(cxi - half, cyi - half, S, S, pBits)
        gm := GreenMatch(pBits, S, lcx, lcy, Ro)
        okW := MeasureWhite(pBits, S, lcx, lcy, Ro, rr, nAg)
        bd := ""
        if (TraceOn && !okW && gm >= GreenLostMin && TraceN < TraceMax)
            bd := BrightDump(pBits, S, lcx, lcy, Ro)
        DllCall("DeleteObject", "Ptr", hbm)
        ; белая линия, проходя по светло-зелёной кайме, закрывает контрольные точки кольца:
        ; тогда кольцо считаем на месте, если белая линия измерена рядом с каймой
        okW0 := okW
        present := (gm >= GreenLostMin)
        if (!present && okW && rr >= Ro - 16 * Scl && rr <= Ro + 6 * Scl)
            present := true
        if (present) {
            lastSeen := tNow
            lastRingT := tNow
        }
        else
            okW := false

        if (tNow - lastSeen > LostMs) {
            tracking := false
            Trace("LOST (no ring for " . LostMs . " ms)")
            Status("Ring gone - searching...")
            continue
        }

        if (okW) {
            if (haveR) {
                dts := (tNow - pT) / 1000
                if (dts > 0.003 && dts < 0.3)
                    v := v * 0.5 + ((rr - pR) / dts) * 0.5
            }
            pR := rr
            pT := tNow
            haveR := true
            nS += 1

            bandIn := Ro - TargetInOff * Scl
            bandOut := Ro - TargetOutOff * Scl
            bw := bandOut - bandIn
            rPred := rr + v * PressLatencyMs / 1000

            if (armed) {
                if (nS >= 2) {
                    vmin := MinSpeedK * Ro
                    go := false
                    if (v < -vmin) {
                        ; линия идёт внутрь: жмём, как только она дошла до pf-доли полосы (с запасом на пропуск кадра)
                        go := (rPred <= bandOut - pf * bw && rPred >= bandIn - 1.0 * bw)
                    } else if (v > vmin) {
                        go := (rPred >= bandIn + pf * bw && rPred <= bandOut + 1.0 * bw)
                    } else {
                        go := (rPred >= bandIn && rPred <= bandOut)
                    }
                    if (go) {
                        f := (v > vmin) ? (rPred - bandIn) / bw : (bandOut - rPred) / bw
                        PressKey()
                        Presses += 1
                        armed := false
                        pressT := Now()
                        Status("PRESS #" . Presses . "  r=" . Round(rr, 1) . "  v=" . Round(v))
                        FileAppend, % "press " . Presses . ": r=" . Round(rr, 1) . " rPred=" . Round(rPred, 1) . " v=" . Round(v) . " Ro=" . Round(Ro, 1) . " target=" . Round(bandIn, 1) . ".." . Round(bandOut, 1) . " frac=" . Round(f, 2) . "`n", %A_ScriptDir%\kachalka_press_log.txt, UTF-8
                    }
                }
            } else if (tNow - pressT >= MinRepeatMs) {
                gap := RearmGapK * Ro
                if (rr < bandIn - gap || rr > bandOut + gap) {
                    armed := true
                    pf := RandF(PressFracMin, PressFracMax)
                }
            }

            if (tNow - lastStat > 500) {
                lastStat := tNow
                Status("TRACK r=" . Round(rr, 1) . " (" . Round(rr / Ro, 3) . ")  v=" . Round(v) . "  presses=" . Presses)
            }
        }

        if (bd != "")
            Trace("BRIGHT " . bd)
        Trace("gm=" . gm . " white=" . okW0 . " r=" . Round(rr, 1) . " rays=" . nAg . " Ro=" . Round(Ro, 1) . " v=" . Round(v) . " armed=" . armed . " target=" . Round(Ro - TargetInOff * Scl, 1) . ".." . Round(Ro - TargetOutOff * Scl, 1))
        Sleep, % LoopSleepMs
    }
}

Trace(txt) {
    global TraceOn, TraceN, TraceMax, TraceT0
    if (!TraceOn || TraceN >= TraceMax)
        return
    TraceN += 1
    FileAppend, % Round(Now() - TraceT0) . " " . txt . "`n", %A_ScriptDir%\kachalka_trace.txt, UTF-8
}

; для журнала: самый светлый пиксель на 8 лучах (по минимальному каналу) и его радиус.
; Показывает настоящий цвет линии, когда она не опознана как линия.
BrightDump(pBits, S, lcx, lcy, Ro) {
    global ScanMinK, ScanMaxK
    out := ""
    r0 := Round(ScanMinK * Ro)
    r1 := Round(ScanMaxK * Ro)
    k := 0
    while (k < 8) {
        ang := 6.28318530717958 * k / 8 + 0.3
        dx := Cos(ang)
        dy := Sin(ang)
        best := -1
        bestTxt := ""
        rad := r0
        while (rad <= r1) {
            x := Round(lcx + dx * rad)
            y := Round(lcy + dy * rad)
            if (x >= 0 && x < S && y >= 0 && y < S) {
                c := NumGet(pBits + 0, (y * S + x) * 4, "UInt")
                r := (c >> 16) & 255
                g := (c >> 8) & 255
                b := c & 255
                m := (r < g) ? r : g
                if (b < m)
                    m := b
                if (m > best) {
                    best := m
                    bestTxt := rad . ":" . r . "," . g . "," . b
                }
            }
            rad += 1
        }
        out .= bestTxt . " "
        k += 1
    }
    return out
}

; клик в точку (0,0 = центр экрана): сдвиг мыши, пауза, нажатие с удержанием - игре так надёжнее
ClickPoint(x, y) {
    if (x <= 0 && y <= 0) {
        x := A_ScreenWidth // 2
        y := A_ScreenHeight // 2
    }
    MouseMove, % x - 3, % y - 3, 2
    Sleep, 80
    MouseMove, % x, % y, 2
    Sleep, 120
    Click, down
    Sleep, 70
    Click, up
}

PressSc(dn, up) {
    global KeyHoldMin, KeyHoldMax
    SendEvent, %dn%
    Sleep, % RandInt(KeyHoldMin, KeyHoldMax)
    SendEvent, %up%
}

PressKey() {
    global KeyDown, KeyUp, KeyHoldMin, KeyHoldMax
    SendEvent, %KeyDown%
    Sleep, % RandInt(KeyHoldMin, KeyHoldMax)
    SendEvent, %KeyUp%
}

; =====================================================================
; ПОИСК ЗЕЛЁНОГО КОЛЬЦА В ОБЛАСТИ (RX,RY,RW,RH)
; возвращает центр (экранные координаты) и внешний радиус в px
; =====================================================================
FindRing(ByRef outCX, ByRef outCY, ByRef outRo) {
    global RX, RY, RW, RH, Scl, RefDiam, FindInfo
    hbm := CaptureDIB(RX, RY, RW, RH, pBits)
    found := false
    FindInfo := "no green pixels in region"
    ScanGreen(pBits, RW, 0, 0, RW - 1, RH - 1, 3, n, bx1, bx2, by1, by2)
    expD := RefDiam * Scl
    FindInfo := "green pixels (sampled): " . n . " (need 60)"
    if (n >= 60) {
        w := bx2 - bx1 + 1
        h := by2 - by1 + 1
        mx := (w > h) ? w : h
        FindInfo := "coarse box " . w . "x" . h . " (need square, 0.4..2.0 x " . Round(expD) . ")"
        if (w >= 0.4 * expD && w <= 2.0 * expD && Abs(w - h) <= 0.08 * mx) {
            ; уточняем границы шагом 1 px
            ScanGreen(pBits, RW, Max(0, bx1 - 4), Max(0, by1 - 4), Min(RW - 1, bx2 + 4), Min(RH - 1, by2 + 4), 1, n2, x1, x2, y1, y2)
            w := x2 - x1 + 1
            h := y2 - y1 + 1
            mx := (w > h) ? w : h
            FindInfo := "refined box " . w . "x" . h . " (need square)"
            if (Abs(w - h) <= 0.04 * mx) {
                cxl := (x1 + x2) / 2
                cyl := (y1 + y2) / 2
                Ro := (mx - 1) / 2
                gmm := GreenMatch(pBits, RW, cxl, cyl, Ro)
                FindInfo := "ring check " . gmm . "/16 green points (need 12)"
                if (gmm >= 12) {
                    outCX := RX + cxl
                    outCY := RY + cyl
                    outRo := Ro
                    found := true
                }
            }
        }
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return found
}

ScanGreen(pBits, W, x1, y1, x2, y2, stp, ByRef n, ByRef bx1, ByRef bx2, ByRef by1, ByRef by2) {
    global GreenGMin, GreenRG, GreenBG
    n := 0
    colc := []
    rowc := []
    y := y1
    while (y <= y2) {
        base := y * W * 4
        x := x1
        while (x <= x2) {
            c := NumGet(pBits + 0, base + x * 4, "UInt")
            r := (c >> 16) & 255
            g := (c >> 8) & 255
            b := c & 255
            if (g >= GreenGMin && g - r >= GreenRG && g - b >= GreenBG) {
                n += 1
                cv := colc[x]
                colc[x] := (cv = "") ? 1 : cv + 1
                rv := rowc[y]
                rowc[y] := (rv = "") ? 1 : rv + 1
            }
            x += stp
        }
        y += stp
    }
    bx1 := x1
    bx2 := x2
    by1 := y1
    by2 := y2
    if (n = 0)
        return
    thr := (stp = 1) ? 3 : 2
    x := x1
    while (x <= x2) {
        if (colc[x] >= thr) {
            bx1 := x
            break
        }
        x += 1
    }
    x := x2
    while (x >= x1) {
        if (colc[x] >= thr) {
            bx2 := x
            break
        }
        x -= 1
    }
    y := y1
    while (y <= y2) {
        if (rowc[y] >= thr) {
            by1 := y
            break
        }
        y += 1
    }
    y := y2
    while (y >= y1) {
        if (rowc[y] >= thr) {
            by2 := y
            break
        }
        y -= 1
    }
}

; сколько из 16 контрольных точек на зелёном кольце действительно зелёные
GreenMatch(pBits, W, lcx, lcy, Ro) {
    global GreenGMin, GreenRG, GreenBG
    cnt := 0
    rad := 0.965 * Ro
    i := 0
    while (i < 16) {
        ang := 6.28318530717958 * i / 16
        x := Round(lcx + rad * Cos(ang))
        y := Round(lcy + rad * Sin(ang))
        if (x >= 0 && x < W && y >= 0) {
            c := NumGet(pBits + 0, (y * W + x) * 4, "UInt")
            r := (c >> 16) & 255
            g := (c >> 8) & 255
            b := c & 255
            if (g >= GreenGMin && g - r >= GreenRG && g - b >= GreenBG)
                cnt += 1
        }
        i += 1
    }
    return cnt
}

; радиус белого кольца: на каждом луче от центра ищем белую полосу толщиной 2..0.12*Ro px,
; затем берём медиану по лучам и требуем, чтобы не меньше половины лучей с ней согласились
MeasureWhite(pBits, S, lcx, lcy, Ro, ByRef rOut, ByRef nAgree) {
    global RayC, RayS, NRays, ScanMinK, ScanMaxK, LineRMin, LineGMin, LineBMin
    rs := []
    r0 := Round(ScanMinK * Ro)
    r1 := Round(ScanMaxK * Ro)
    maxRun := Max(4, Round(0.12 * Ro))
    i := 1
    while (i <= NRays) {
        dx := RayC[i]
        dy := RayS[i]
        wrun := 0
        runStart := 0
        found := 0
        rad := r0
        while (rad <= r1) {
            x := Round(lcx + dx * rad)
            y := Round(lcy + dy * rad)
            white := false
            if (x >= 0 && x < S && y >= 0 && y < S) {
                c := NumGet(pBits + 0, (y * S + x) * 4, "UInt")
                r := (c >> 16) & 255
                g := (c >> 8) & 255
                b := c & 255
                if (r >= LineRMin && g >= LineGMin && b >= LineBMin)
                    white := true
            }
            if (white) {
                if (wrun = 0)
                    runStart := rad
                wrun += 1
            } else {
                if (wrun >= 2 && wrun <= maxRun) {
                    found := runStart + (wrun - 1) / 2
                    break
                }
                wrun := 0
            }
            rad += 1
        }
        if (found > 0)
            rs.Push(found)
        i += 1
    }
    n := rs.Length()
    nAgree := 0
    if (n < 1)
        return false
    k := 2
    while (k <= n) {
        key := rs[k]
        j := k - 1
        while (j >= 1 && rs[j] > key) {
            rs[j + 1] := rs[j]
            j -= 1
        }
        rs[j + 1] := key
        k += 1
    }
    med := rs[(n + 1) // 2]
    tol := Max(2.5, 0.025 * Ro)
    acc := 0
    k := 1
    while (k <= n) {
        if (Abs(rs[k] - med) <= tol) {
            acc += rs[k]
            nAgree += 1
        }
        k += 1
    }
    if (nAgree < 0.5 * NRays)
        return false
    rOut := acc / nAgree
    return true
}

CaptureDIB(X, Y, W, H, ByRef pBits) {
    VarSetCapacity(bi, 40, 0)
    NumPut(40, bi, 0, "UInt")
    NumPut(W, bi, 4, "Int")
    NumPut(-H, bi, 8, "Int")
    NumPut(1, bi, 12, "UShort")
    NumPut(32, bi, 14, "UShort")
    HDC := DllCall("GetDC", "Ptr", 0, "UPtr")
    pBits := 0
    hbm := DllCall("CreateDIBSection", "Ptr", HDC, "Ptr", &bi, "UInt", 0, "Ptr*", pBits, "Ptr", 0, "UInt", 0, "UPtr")
    dc := DllCall("CreateCompatibleDC", "Ptr", HDC, "UPtr")
    DllCall("SelectObject", "Ptr", dc, "Ptr", hbm)
    DllCall("BitBlt", "Ptr", dc, "Int", 0, "Int", 0, "Int", W, "Int", H, "Ptr", HDC, "Int", X, "Int", Y, "UInt", 0x00CC0020)
    DllCall("DeleteDC", "Ptr", dc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", HDC)
    return hbm
}

; =====================================================================
; F8: диагностика. Откройте мини-игру, нажмите F8, пришлите kachalka_debug.txt и scan_region_kachalka.bmp
; =====================================================================
DebugScan() {
    global RX, RY, RW, RH, Scl, RefDiam, TargetInOff, TargetOutOff, ScanMaxK, FindInfo
    Status("Scanning...")
    t0 := A_TickCount
    ok := FindRing(cx, cy, Ro)
    ms := A_TickCount - t0
    txt := "screen " . A_ScreenWidth . "x" . A_ScreenHeight . "  region " . RX . "," . RY . " " . RW . "x" . RH . "`n"
    if (ok) {
        txt .= "ring FOUND centre (" . Round(cx, 1) . "," . Round(cy, 1) . ")  outer radius " . Round(Ro, 1) . " px  diameter " . Round(2 * Ro + 1) . " px  (reference " . RefDiam . ")`n"
        txt .= "ring size vs reference: " . Round((2 * Ro + 1) / RefDiam, 3) . "  (screen height scale: " . Round(Scl, 3) . ")`n"
        txt .= "target radius: " . Round(Ro - TargetInOff * Scl, 1) . " .. " . Round(Ro - TargetOutOff * Scl, 1) . " px`n"
        cxi := Round(cx)
        cyi := Round(cy)
        half := Ceil(ScanMaxK * Ro) + 2
        S := 2 * half + 1
        hbm := CaptureDIB(cxi - half, cyi - half, S, S, pBits)
        gm := GreenMatch(pBits, S, half + (cx - cxi), half + (cy - cyi), Ro)
        okW := MeasureWhite(pBits, S, half + (cx - cxi), half + (cy - cyi), Ro, rr, nAg)
        DllCall("DeleteObject", "Ptr", hbm)
        txt .= "green check: " . gm . " / 16`n"
        if (okW)
            txt .= "white ring radius " . Round(rr, 1) . " px (" . Round(rr - Ro, 1) . " px relative to outer radius; negative = inside), rays agree " . nAg . " / 40`n"
        else
            txt .= "white ring NOT found`n"
        Status("SCAN OK: ring D=" . Round(2 * Ro + 1) . "px (" . ms . " ms)")
    } else {
        txt .= "ring NOT found. " . FindInfo . "`n"
        Status("SCAN: ring not found - check region (F9) or green colour limits")
    }
    txt .= "time: " . ms . " ms`n"
    FileDelete, %A_ScriptDir%\kachalka_debug.txt
    FileAppend, %txt%, %A_ScriptDir%\kachalka_debug.txt, UTF-8
    hbm := CaptureDIB(RX, RY, RW, RH, pBits)
    SaveBMP(pBits, RW, RH, A_ScriptDir . "\scan_region_kachalka.bmp")
    DllCall("DeleteObject", "Ptr", hbm)
}

SaveBMP(pBits, W, H, path) {
    size := W * H * 4
    VarSetCapacity(hdr, 54, 0)
    NumPut(0x4D42, hdr, 0, "UShort")
    NumPut(54 + size, hdr, 2, "UInt")
    NumPut(54, hdr, 10, "UInt")
    NumPut(40, hdr, 14, "UInt")
    NumPut(W, hdr, 18, "Int")
    NumPut(-H, hdr, 22, "Int")
    NumPut(1, hdr, 26, "UShort")
    NumPut(32, hdr, 28, "UShort")
    NumPut(size, hdr, 34, "UInt")
    f := FileOpen(path, "w")
    f.RawWrite(hdr, 54)
    f.RawWrite(pBits + 0, size)
    f.Close()
}

Now() {
    static freq := 0
    if (!freq)
        DllCall("QueryPerformanceFrequency", "Int64*", freq)
    DllCall("QueryPerformanceCounter", "Int64*", cnt)
    return cnt * 1000 / freq
}

RandF(a, b) {
    Random, r, 0.0, 1.0
    return a + r * (b - a)
}

RandInt(a, b) {
    Random, r, %a%, %b%
    return r
}
