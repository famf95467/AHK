if not A_IsAdmin {
    Run *RunAs "%A_AhkPath%" "%A_ScriptFullPath%"
    ExitApp
}

#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
SendMode Event
SetBatchLines -1
SetMouseDelay, -1
CoordMode, Mouse, Screen
CoordMode, Pixel, Screen
DllCall("SetProcessDPIAware")
DllCall("winmm\timeBeginPeriod", "UInt", 1)

; =====================================================================
; НАСТРОЙКИ
; =====================================================================
global TimerMax   := 69
global SatPct     := 70
global CircleD    := 50
global OffsetX    := 0
global OffsetY    := 0
global Running    := false
global Busy       := false
global TimerStart := 0
global RegionStep := 0
global RegX1      := 0
global RegY1      := 0

; >>> имитация промахов (радиус кружка = CircleD/2 = 25px; дистанция > 25 = реально мимо)
global MissChance       := 0.30   ; шанс случайного промаха (проверка раз в 250 мс)
global MissDistMin      := 35     ; px от центра кружка, большой промах
global MissDistMax      := 60
global SharpDistMin     := 30     ; px от центра кружка, небольшой промах (резкий поворот)
global SharpDistMax     := 50
global MissDurMin       := 220    ; ms, длительность промаха
global MissDurMax       := 450
global ReturnTauK       := 0.55   ; чуть медленнее возврат (было 0.40)
global TurnDot          := 0.80   ; cos угла «резкого поворота» (было 0.75 — чаще срабатывает)
global ReverseDot       := -0.50  ; cos угла разворота (было -0.60 — чаще срабатывает)
global SharpChance      := 0.75   ; шанс промаха на резком повороте (было 0.40)
global ReverseChance    := 1.00   ; шанс промаха при развороте (было 0.90)
global DiagMin          := 0.85   ; почти отключаем «идеальную диагональ» (было 0.35)

; >>> конец игры: кружок пропал на столько мс => окно закрылось, больше не ищем
global LostMs           := 250

global Scl := A_ScreenHeight / 1080
global RX := Round(650 * A_ScreenWidth  / 1920)
global RY := Round(660 * A_ScreenHeight / 1080)
global RW := Round(620 * A_ScreenWidth  / 1920)
global RH := Round(325 * A_ScreenHeight / 1080)

IniRead, rectStr, %A_ScriptDir%\tokarka.ini, Region, Rect, ERROR
if (rectStr != "ERROR") {
    StringSplit, rc, rectStr, `,
    if (rc0 = 4 && rc3 > 80 && rc4 > 80) {
        RX := rc1 + 0
        RY := rc2 + 0
        RW := rc3 + 0
        RH := rc4 + 0
    }
}

Gui, St:+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
Gui, St:Color, 000000
Gui, St:Font, s16 bold, Arial
Gui, St:Add, Text, vStTxt cLime w900, READY: F6 start | F7 exit | F8 scan | F9 region
Gui, St:Show, x20 y20 NoActivate
WinSet, Transparent, 210

Gui, Tm:+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
Gui, Tm:Color, 000000
Gui, Tm:Font, s20 bold, Arial
Gui, Tm:Add, Text, vTmTxt cYellow w260, TIMER 0 / %TimerMax%
Gui, Tm:Show, x20 y70 NoActivate
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

Status(txt) {
    GuiControl, St:, StTxt, %txt%
    Sleep, 1
}

TimerStartNow() {
    global TimerStart, TimerMax
    TimerStart := A_TickCount
    GuiControl, Tm:, TmTxt, % "TIMER 0 / " . TimerMax
    SetTimer, TimerTick, 250
}

TimerStopNow() {
    global TimerMax
    SetTimer, TimerTick, Off
    GuiControl, Tm:, TmTxt, % "TIMER 0 / " . TimerMax
}

TimerTick:
    secs := (A_TickCount - TimerStart) // 1000
    if (secs >= TimerMax) {
        secs := TimerMax
        SetTimer, TimerTick, Off
    }
    GuiControl, Tm:, TmTxt, % "TIMER " . secs . " / " . TimerMax
return

; =====================================================================
; ГОРЯЧИЕ КЛАВИШИ
; =====================================================================
F6::
    if (Running) {
        Running := false
        Status("STOPPING...")
    } else if (!Busy) {
        Running := true
        Status("RUNNING (F6 = stop)")
        SetTimer, DoWork, -10
    }
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
        IniWrite, %RX%`,%RY%`,%RW%`,%RH%, %A_ScriptDir%\tokarka.ini, Region, Rect
        Status("REGION saved: " . RX . "," . RY . " " . RW . "x" . RH)
    }
return

DoWork:
    Busy := true
    resTrack := Track()
    Busy := false
    Running := false
    if (resTrack = "done") {
        Status("COMPLETE (F6 = restart)")
    } else {
        TimerStopNow()
        Status("STOPPED")
    }
return

; =====================================================================
; ГЛАВНЫЙ ЦИКЛ
; =====================================================================
Track() {
    global Running, RX, RY, RW, RH, Scl, TimerMax, OffsetX, OffsetY
    global MissChance, MissDistMin, MissDistMax, SharpDistMin, SharpDistMax, MissDurMin, MissDurMax
    global TurnDot, ReverseDot, SharpChance, ReverseChance, DiagMin, LostMs, ReturnTauK

    MouseGetPos, mx0, my0
    cx := mx0 + 0.0
    cy := my0 + 0.0
    hasLast := false
    havePrev := false
    fx := 0
    fy := 0
    pfx := 0
    pfy := 0
    pT := 0
    vx := 0
    vy := 0
    ox := 0
    oy := 0
    twx := 0
    twy := 0
    tau := RandF(0.045, 0.085)
    lead := tau + RandF(-0.012, 0.02)
    side := (RandF(0.0, 1.0) < 0.5) ? -1 : 1
    tNow := Now()
    tPrev := tNow
    leadNext := tNow + 1500
    nextFreeze := tNow + RandF(6000, 14000)
    freezeUntil := 0
    lastSeen := 0
    lastStat := 0
    tAcq := 0
    tStart := 0
    started := false

    ; >>> состояние промахов / поворотов
    missStart := 0
    missEnd := 0
    missX := 0
    missY := 0
    missIsTurn := false
    lastMissCheck := 0
    sdx := 0
    sdy := 0
    oldAng := 0
    watching := false
    watchUntil := 0
    turnCool := 0
    turnDecided := false
    minDot := 1.0

    Status("Searching circle...")

    Loop {
        if (!Running)
            return "stopped"

        tNow := Now()
        dt := (tNow - tPrev) / 1000
        tPrev := tNow
        if (dt < 0.002)
            dt := 0.002
        if (dt > 0.2)
            dt := 0.2

        ; таймер истёк — выходим
        if (started && tNow - tStart >= TimerMax * 1000)
            return "done"

        ; --- где сейчас кружок ---
        ok := LocateCircle(hasLast, fx, fy, nfx, nfy, area)
        if (ok) {
            if (havePrev) {
                dts := (tNow - pT) / 1000
                if (dts > 0.004 && dts < 0.4) {
                    vx := vx * 0.72 + ((nfx - pfx) / dts) * 0.28
                    vy := vy * 0.72 + ((nfy - pfy) / dts) * 0.28
                }
            }
            if (!hasLast)
                tAcq := tNow
            pfx := nfx
            pfy := nfy
            pT := tNow
            havePrev := true
            fx := nfx
            fy := nfy
            hasLast := true
            lastSeen := tNow
            if (!started) {
                started := true
                tStart := tNow
                TimerStartNow()
                Status("TRACKING (F6 = stop)")
            }
        } else if (hasLast) {
            ; >>> кружок пропал (окно закрылось) — больше не ищем, ждём конца таймера или F6
            if (tNow - lastSeen > LostMs)
                return WaitFinish(tStart, "Circle gone")
            ; пока решаем, закрылось ли окно — мышь НЕ двигаем вообще (никакой экстраполяции и дрожи)
            Sleep, 10
            continue
        } else {
            ; ещё ни разу не нашли — ищем до старта
            Sleep, 40
            continue
        }

        if (!hasLast) {
            Sleep, 40
            continue
        }

        ; --- параметры «руки» ---
        if (tNow > leadNext) {
            tau := RandF(0.045, 0.085)
            lead := tau + RandF(-0.012, 0.02)
            leadNext := tNow + RandF(1200, 2600)
        }
        speed := Sqrt(vx * vx + vy * vy)

        ; >>> диагональ: кружок уверенно едет по диагонали (обе компоненты скорости заметны)
        diag := false
        if (!watching && speed > 40 * Scl) {
            avx := Abs(vx)
            avy := Abs(vy)
            hiV := (avx > avy) ? avx : avy
            loV := (avx > avy) ? avy : avx
            if (loV / hiV > DiagMin)
                diag := true
        }

        lim := Max(2.5 * Scl, Min(9 * Scl, 19 * Scl - speed * 0.03 - 3 * Scl))
        if (diag)
            lim *= 0.85   ; было 0.3 — на диагонали дрожание почти как обычно
        kick := 2.6 * Scl * Sqrt(dt / 0.033)
        decay := Exp(-dt / 0.8)
        ox := ox * decay + RandF(-1.0, 1.0) * kick
        oy := oy * decay + RandF(-1.0, 1.0) * kick
        ox := Max(-lim, Min(lim, ox))
        oy := Max(-lim, Min(lim, oy))

        if (!diag && RandF(0.0, 1.0) < 0.012) {
            twx := RandF(-2.5, 2.5)
            twy := RandF(-2.5, 2.5)
        }
        twx *= 0.6
        twy *= 0.6

        if (tNow > nextFreeze) {
            if (speed * 0.14 < 5 * Scl) {
                freezeUntil := tNow + RandF(80, 150)
                nextFreeze := tNow + RandF(6000, 14000)
            } else {
                nextFreeze := tNow + 1500
            }
        }

        ; >>> анализ направления: сравниваем текущее направление кружка со «старым» (медленно усреднённым)
        dotNow := 1.0
        haveDot := false
        if (speed > 25 * Scl) {
            ux := vx / speed
            uy := vy / speed
            sm0 := Sqrt(sdx * sdx + sdy * sdy)
            if (sm0 < 0.05) {
                sdx := ux
                sdy := uy
            } else {
                dotNow := (ux * sdx + uy * sdy) / sm0
                haveDot := true
                if (!watching && tNow > turnCool && dotNow < TurnDot) {
                    ; начался резкий поворот — запоминаем старое направление и наблюдаем ~130 мс
                    watching := true
                    watchUntil := tNow + 130
                    minDot := dotNow
                    oldAng := ATan2(sdy, sdx)
                    turnDecided := false
                }
                if (!watching) {
                    kk := 1 - Exp(-dt / 0.18)
                    sdx += (ux - sdx) * kk
                    sdy += (uy - sdy) * kk
                }
            }
        }

        if (watching) {
            if (haveDot) {
                if (dotNow < minDot)
                    minDot := dotNow
            } else if (speed <= 25 * Scl) {
                ; скорость просела почти до нуля = разворот
                if (minDot > -0.5)
                    minDot := -0.5
            }

            ; разворот на ~180 => промах с шансом 90%, перелёт по старому направлению
            if (!turnDecided && minDot < ReverseDot) {
                turnDecided := true
                if (RandF(0.0, 1.0) < ReverseChance) {
                    dist := RandF(MissDistMin, MissDistMax) * Scl
                    ang2 := oldAng + RandF(-0.35, 0.35)
                    missX := Cos(ang2) * dist
                    missY := Sin(ang2) * dist
                    missStart := tNow
                    missEnd := tNow + RandF(MissDurMin, MissDurMax)
                    missIsTurn := true
                }
            }

            if (tNow >= watchUntil) {
                if (!turnDecided) {
                    ; обычный резкий поворот (не разворот) => небольшой промах / вылет
                    turnDecided := true
                    if (RandF(0.0, 1.0) < SharpChance) {
                        dist := RandF(SharpDistMin, SharpDistMax) * Scl
                        ang2 := oldAng + RandF(-0.6, 0.6)
                        missX := Cos(ang2) * dist
                        missY := Sin(ang2) * dist
                        missStart := tNow
                        missEnd := tNow + RandF(MissDurMin * 0.7, MissDurMax * 0.7)
                        missIsTurn := true
                    }
                }
                watching := false
                turnCool := tNow + 400
            }
        }

        ; >>> на диагонали случайный промах больше НЕ отменяем — оставляем как есть
        ; (блок отмены промаха на диагонали удалён)

        if (!diag && !watching && tNow > missEnd && tNow - lastMissCheck > 250) {
            lastMissCheck := tNow
            if (RandF(0.0, 1.0) < MissChance) {
                dist := RandF(SharpDistMin, MissDistMax) * Scl
                ang2 := RandF(0.0, 6.2831853)
                missX := Cos(ang2) * dist
                missY := Sin(ang2) * dist
                missStart := tNow
                missEnd := tNow + RandF(MissDurMin, MissDurMax)
                missIsTurn := false
            }
        }

        ; --- цель с упреждением ---
        ax := fx + vx * lead + ox + OffsetX
        ay := fy + vy * lead + oy + OffsetY

        ; >>> во время промаха цель уезжает от центра кружка (плавно: разгон / удержание / возврат)
        if (tNow < missEnd) {
            p := (tNow - missStart) / (missEnd - missStart)
            w := 1.0
            if (p < 0.35) {
                w := p / 0.35
            } else if (p > 0.85) {
                w := (1.0 - p) / 0.15
            }
            ax += missX * w
            ay += missY * w
        }

        ex := ax - cx
        ey := ay - cy
        ed := Sqrt(ex * ex + ey * ey)
        if (ed > 80 * Scl) {
            ax += -ey / ed * side * ed * 0.16
            ay += ex / ed * side * ed * 0.16
            ex := ax - cx
            ey := ay - cy
        } else if (ed < 25 * Scl && RandF(0.0, 1.0) < 0.02) {
            side := -side
        }

        if (tNow >= freezeUntil) {
            tauEff := diag ? tau * 0.7 : tau
            ; быстрый возврат на кружок после промаха
            if (missEnd > 0 && tNow > missStart + 0.7 * (missEnd - missStart) && tNow < missEnd + 120)
                tauEff := tau * ReturnTauK
            gain := 1 - Exp(-dt / tauEff)
            sx := ex * gain
            sy := ey * gain
            vmax := (500 + 1600 * Min(1, (tNow - tAcq) / 260)) * Scl   ; было 2400 — рука не «нагоняет» мгновенно
            sm := Sqrt(sx * sx + sy * sy)
            lim2 := vmax * dt
            if (sm > lim2 && sm > 0) {
                sx *= lim2 / sm
                sy *= lim2 / sm
            }
            cx += sx
            cy += sy
        }

        MouseMove, % Round(cx + twx), % Round(cy + twy), 0

        if (tNow - lastStat > 700) {
            lastStat := tNow
            Status("TRACK " . Round(fx) . "," . Round(fy) . "  v=" . Round(speed) . (diag ? "  DIAG" : ""))
        }
        Sleep, % RandInt(3, 8)
    }
}

; Ждём конца таймера или F6. Экран НЕ сканируется, мышь НЕ двигается.
WaitFinish(tStart, reason) {
    global Running, TimerMax
    Status(reason . " - waiting for timer end (F6 = stop)")
    Loop {
        if (!Running)
            return "stopped"
        if (Now() - tStart >= TimerMax * 1000)
            return "done"
        Sleep, 100
    }
}

; =====================================================================
; Вспомогательные для углов
; =====================================================================
ATan2(y, x) {
    ; корректный atan2 в радианах
    if (x > 0)
        return ATan(y / x)
    if (x < 0 && y >= 0)
        return ATan(y / x) + 3.14159265358979
    if (x < 0 && y < 0)
        return ATan(y / x) - 3.14159265358979
    if (x = 0 && y > 0)
        return 3.14159265358979 / 2
    if (x = 0 && y < 0)
        return -3.14159265358979 / 2
    return 0
}

AngleDiff(a, b) {
    ; кратчайшая разница углов в диапазоне [-pi, pi]
    d := a - b
    while (d > 3.14159265358979)
        d -= 6.28318530717958
    while (d < -3.14159265358979)
        d += 6.28318530717958
    return d
}

; =====================================================================
; Поиск кружка (без изменений)
; =====================================================================
LocateCircle(useLast, lx, ly, ByRef outX, ByRef outY, ByRef area) {
    global RX, RY, RW, RH, Scl, CircleD
    hbm := CaptureDIB(RX, RY, RW, RH, pBits)
    found := false
    if (useLast) {
        half := Round(64 * Scl)
        x1 := Max(0, Round(lx - RX) - half)
        x2 := Min(RW - 1, Round(lx - RX) + half)
        y1 := Max(0, Round(ly - RY) - half)
        y2 := Min(RH - 1, Round(ly - RY) + half)
        stp := 2
        minN := 40
    } else {
        x1 := 0
        x2 := RW - 1
        y1 := 0
        y2 := RH - 1
        stp := 3
        minN := 25
    }
    ScanBlob(pBits, RW, x1, y1, x2, y2, stp, sx, sy, n, bx1, bx2, by1, by2)
    if (n >= minN) {
        mxr := sx / n
        myr := sy / n
        rr := Round(30 * Scl)
        x1 := Max(0, Round(mxr) - rr)
        x2 := Min(RW - 1, Round(mxr) + rr)
        y1 := Max(0, Round(myr) - rr)
        y2 := Min(RH - 1, Round(myr) + rr)
        ScanBlob(pBits, RW, x1, y1, x2, y2, 1, sx2, sy2, n2, bx1, bx2, by1, by2)
        ; слабое пятно (n2 < 300) не считаем кружком — это защита от ложных срабатываний,
        ; когда окно уже закрылось
        minFull := 300
        if (useLast)
            minFull := Max(300, 0.45 * 3.14159 * (CircleD * Scl / 2) ** 2)
        if (n2 >= minFull) {
            cxr := sx2 / n2
            cyr := sy2 / n2
            dd := CircleD * Scl
            if (bx2 - bx1 + 1 >= 0.88 * dd)
                cxr := (bx1 + bx2) / 2
            if (by2 - by1 + 1 >= 0.88 * dd)
                cyr := (by1 + by2) / 2
            else
                cyr := by2 - dd / 2 + 0.5
            outX := RX + cxr + 0.5
            outY := RY + cyr + 0.5
            area := n2
            found := true
        }
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return found
}

ScanBlob(pBits, W, x1, y1, x2, y2, stp, ByRef sx, ByRef sy, ByRef n, ByRef bx1, ByRef bx2, ByRef by1, ByRef by2) {
    global SatPct
    sx := 0
    sy := 0
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
            hi := (r > g) ? r : g
            if (b > hi)
                hi := b
            lo := (r < g) ? r : g
            if (b < lo)
                lo := b
            if (hi > 90 && (hi - lo) * 100 > SatPct * hi) {
                sx += x
                sy += y
                n += 1
                colc[x] += 1
                rowc[y] += 1
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

DebugScan() {
    global RX, RY, RW, RH
    Status("Scanning...")
    t0 := A_TickCount
    ok := LocateCircle(false, 0, 0, fx, fy, area)
    ms := A_TickCount - t0
    txt := "screen " . A_ScreenWidth . "x" . A_ScreenHeight . "  region " . RX . "," . RY . " " . RW . "x" . RH . "`n"
    if (ok) {
        MouseGetPos, mx, my
        txt .= "circle FOUND at (" . Round(fx) . "," . Round(fy) . ") area=" . area . "px`n"
        txt .= "cursor at (" . mx . "," . my . ")`n"
        Status("SCAN OK: circle at " . Round(fx) . "," . Round(fy) . " (" . ms . " ms)")
    } else {
        txt .= "circle NOT found`n"
        Status("SCAN: circle not found - check region (F9) or SatPct")
    }
    txt .= "time: " . ms . " ms`n"
    FileDelete, %A_ScriptDir%\debug.txt
    FileAppend, %txt%, %A_ScriptDir%\debug.txt, UTF-8
    hbm := CaptureDIB(RX, RY, RW, RH, pBits)
    SaveBMP(pBits, RW, RH, A_ScriptDir . "\scan_region.bmp")
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