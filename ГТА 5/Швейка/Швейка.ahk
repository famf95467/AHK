; Автозапуск от имени администратора
if not A_IsAdmin {
    Run *RunAs "%A_AhkPath%" "%A_ScriptFullPath%"
    ExitApp
}

#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
SendMode Event
SetBatchLines -1
SetMouseDelay, 10
CoordMode, Mouse, Screen
CoordMode, Pixel, Screen
DllCall("SetProcessDPIAware")
DllCall("winmm\timeBeginPeriod", "UInt", 1)   ; точный Sleep (1 мс) для плавного движения мыши

; =====================================================================
; НАСТРОЙКИ
; =====================================================================
global N          := 20
global DelayMin   := 3000     ; пауза между кликами (мс)
global DelayMax   := 10000
global PixelJit   := 3        ; (не используется)
global ClickRadius := 8       ; клик в случайном месте внутри круга этого радиуса от центра цифры (px при 1080p)
global CycleDelay := 2000     ; пауза перед новым сканированием после 20 кликов
global TotalMin   := 30000    ; на весь проход по 20 точкам (мс), случайно в этом диапазоне
global TotalMax   := 50000
global TotalFastMin := 25000  ; иногда (FastChance % проходов) быстрый проход
global TotalFastMax := 29000
global FastChance := 12
global RedVar     := 45       ; допуск цвета красной точки (0..255)
global Running    := false
global Busy       := false   ; цикл DoWork ещё выполняется
global TimerMax   := 89      ; таймер цикла считает 0..89 сек
global TimerStart := 0

; Область поиска цифр (тело рубашки), задана для 1920x1080 — масштабируется сама
global Scl := A_ScreenHeight / 1080
global RX := Round(770 * A_ScreenWidth  / 1920)
global RY := Round(330 * A_ScreenHeight / 1080)
global RW := Round(380 * A_ScreenWidth  / 1920)
global RH := Round(475 * A_ScreenHeight / 1080)
global ROWH := 28
global DebugStr := ""
global DebugSave := false
global RegionStep := 0, RegX1 := 0, RegY1 := 0
IniRead, tmpRect, %A_ScriptDir%\sewing.ini, Region, Rect, NONE
if (tmpRect != "NONE") {
    StringSplit, rr, tmpRect, `,
    if (rr3 >= 100 && rr4 >= 100) {
        RX := rr1
        RY := rr2
        RW := rr3
        RH := rr4
    }
}
global GW := 6, GH := 10, MaxCost := 2600, ClCount := 0
global TplF := [], TplW := []

global Px := [], Py := []
global MissingStr := ""
Loop, %N% {
    Px[A_Index] := 0
    Py[A_Index] := 0
}

; Окно статуса (виден поверх игры, мышь не перехватывает)
Gui, St:+AlwaysOnTop -Caption +ToolWindow +E0x20
Gui, St:Color, 000000
Gui, St:Font, s16 bold, Arial
Gui, St:Add, Text, vStTxt cLime w900, READY: F6 start | F8 scan | F9 region | F10 test | F7 exit
Gui, St:Show, x20 y20 NoActivate
WinSet, Transparent, 210, ahk_class AutoHotkeyGUI

; Окно таймера цикла (под статусом, слева сверху)
Gui, Tm:+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
Gui, Tm:Color, 000000
Gui, Tm:Font, s20 bold, Arial
Gui, Tm:Add, Text, vTmTxt cYellow w260, TIMER 0 / %TimerMax%
Gui, Tm:Show, x20 y70 NoActivate
WinSet, Transparent, 210

OnError("ShowErr")
InitTemplates()
return   ; конец автозапуска (дальше только функции, метки и хоткеи)

ShowErr(e) {
    global Running
    Running := false
    Status("ERROR line " . e.Line . ": " . e.Message . " " . e.Extra)
    return true
}

TimerStartNow() {
    global TimerStart, TimerMax
    TimerStart := A_TickCount
    GuiControl, Tm:, TmTxt, % "TIMER 0 / " . TimerMax
    SetTimer, TimerTick, 250
}

TimerFreezeNow() {
    global TimerStart, TimerMax
    SetTimer, TimerTick, Off
    secs := (A_TickCount - TimerStart) // 1000
    if (secs > TimerMax)
        secs := TimerMax
    GuiControl, Tm:, TmTxt, % "DONE " . secs . " / " . TimerMax
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

Status(txt) {
    GuiControl, St:, StTxt, %txt%
    Sleep, 1
}

; =====================================================================
; ГОРЯЧИЕ КЛАВИШИ
; F6  - старт/стоп
; F7  - выход
; F8  - только сканировать и показать, сколько цифр найдено (без кликов)
; F10 - курсор проходит по найденным точкам (без кликов)
; =====================================================================
F6::
    if (Running) {
        ; стоп: цикл сам завершится в ближайшие мс
        Running := false
        Status("STOPPING...")
    } else if (!Busy) {
        Running := true
        Status("RUNNING (F6 = stop)")
        ; запуск через таймер, чтобы поток хоткея сразу завершился
        ; и повторное нажатие F6 не игнорировалось
        SetTimer, DoWork, -10
    }
return

F7::ExitApp

F8::
    Status("Scanning...")
    DebugSave := true
    cnt := ScanPoints()
    DebugSave := false
    if (cnt < 0)
        return
    FileDelete, %A_ScriptDir%\debug.txt
    FileAppend, %DebugStr%, %A_ScriptDir%\debug.txt, UTF-8
    if (cnt >= N)
        Status("SCAN OK: 20/20 found")
    else
        Status("SCAN: " . cnt . "/20 (clusters=" . ClCount . "), missing: " . MissingStr)
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
        IniWrite, %RX%`,%RY%`,%RW%`,%RH%, %A_ScriptDir%\sewing.ini, Region, Rect
        Status("REGION saved: " . RX . "," . RY . " " . RW . "x" . RH)
    }
return

F10::
    Loop, %N% {
        if (Px[A_Index] = 0) {
            Status("TEST: point " . A_Index . " not found")
            Sleep, 400
            continue
        }
        MouseMove, % Px[A_Index], % Py[A_Index], 5
        Status("TEST point " . A_Index . "/" . N)
        Sleep, 500
    }
    Status("TEST finished")
return

; =====================================================================
; ОСНОВНОЙ ЦИКЛ
; =====================================================================
DoWork:
    Busy := true
    hwDone := false
    while (Running) {
        Status("Scanning...")
        cnt := ScanPoints()
        if (cnt < N) {
            if (cnt >= 0)
                Status("SCAN " . cnt . "/20 (clusters=" . ClCount . "), missing: " . MissingStr . " - retry")
            SleepRnd(1000, 1800)
            continue
        }

        ; --- план времени: ближние точки быстрее, у центра дольше ---
        MouseGetPos, hwPrevX, hwPrevY
        hwCx := RX + RW / 2
        hwCy := RY + RH / 2
        hwRc := 0.24 * Min(RW, RH)
        hwSum := 0
        Loop, %N% {
            hwDx := Px[A_Index] - hwPrevX
            hwDy := Py[A_Index] - hwPrevY
            hwDist := Sqrt(hwDx * hwDx + hwDy * hwDy) / Scl
            hwCdx := Px[A_Index] - hwCx
            hwCdy := Py[A_Index] - hwCy
            hwDc := Sqrt(hwCdx * hwCdx + hwCdy * hwCdy)
            hwF := (hwDc < hwRc) ? (1 - hwDc / hwRc) : 0
            HwFc%A_Index% := hwF
            hwWt := (200 + hwDist) * (1 + 1.2 * hwF)
            HwWt%A_Index% := hwWt
            hwSum += hwWt
            hwPrevX := Px[A_Index]
            hwPrevY := Py[A_Index]
        }
        Random, hwRoll, 1, 100
        if (hwRoll <= FastChance)
            Random, hwTotal, %TotalFastMin%, %TotalFastMax%
        else
            Random, hwTotal, %TotalMin%, %TotalMax%

        TimerStartNow()
        Loop, %N% {
            if (!Running)
                break
            i := A_Index
            ; точка клика: случайное место в круге вокруг центра, чуть смещённое в сторону,
            ; откуда пришёл курсор (люди редко попадают ровно в центр)
            MouseGetPos, hwCurX, hwCurY
            hwAng := RandF(0.0, 6.2832)
            hwRad := ClickRadius * Scl * Sqrt(RandF(0.0, 1.0))
            jx := Cos(hwAng) * hwRad
            jy := Sin(hwAng) * hwRad
            hwBx := hwCurX - Px[i]
            hwBy := hwCurY - Py[i]
            hwBd := Sqrt(hwBx * hwBx + hwBy * hwBy)
            if (hwBd > 1) {
                jx += hwBx / hwBd * RandF(0.0, 3.0) * Scl
                jy += hwBy / hwBd * RandF(0.0, 3.0) * Scl
            }
            tx := Round(Px[i] + jx)
            ty := Round(Py[i] + jy)

            hwF := HwFc%i%
            hwSlot := hwTotal * HwWt%i% / hwSum
            hwDeadline := A_TickCount + hwSlot

            MoveHuman(tx, ty, hwSlot * RandF(0.50, 0.62), hwF)
            if (!Running)
                break
            ; зависание над точкой с микро-подрагиванием: у центра заметно дольше
            HoverHuman(RandInt(40, 110) + Round(hwF * RandInt(250, 600)), hwF)
            if (!Running)
                break

            ; числа 2-19 - двойной клик, 1 и 20 - одинарный
            clicks := (i = 1 || i = N) ? 1 : 2
            Loop, %clicks% {
                Click, Down
                Sleep, % RandInt(35, 75)
                Click, Up
                if (A_Index < clicks)
                    Sleep, % RandInt(60, 120)
            }

            Status("CLICK " . i . "/" . N . ((clicks = 2) ? " (double)" : ""))
            if (i < N)
                IdleHuman(hwDeadline)
        }
        if (Running) {
            ; все 20 точек пройдены: цикл завершён, повторный запуск - F6
            hwDone := true
            Running := false
        }
    }
    Busy := false
    if (hwDone) {
        ; таймер продолжает идти до максимума, не останавливаем
        Status("COMPLETE (F6 = restart)")
    } else {
        TimerStopNow()
        Status("STOPPED")
    }
return

RandF(a, b) {
    Random, r, 0.0, 1.0
    return a + r * (b - a)
}

SleepUntil(deadline) {
    global Running
    while (Running && A_TickCount < deadline)
        Sleep, 15
}

Sm(x) {
    return x * x * x * (x * (6 * x - 15) + 10)
}

; Движение к цели в духе человека. Иногда "ищет точку" (уходит назад и разворачивается),
; иногда слегка перелетает. Путь строится алгоритмом WindMouse (гравитация + ветер).
MoveHuman(tx, ty, dur, f) {
    global Running, RX, RY, RW, RH
    MouseGetPos, x0, y0
    dx := tx - x0
    dy := ty - y0
    dist := Sqrt(dx * dx + dy * dy)
    if (dist < 4) {
        MouseMove, %tx%, %ty%, 0
        return
    }
    ux := dx / dist
    uy := dy / dist
    roll := RandF(0.0, 1.0)
    if (dist > 120 && dur > 900 && roll < 0.20) {
        ; сначала не туда (назад/вбок), потом разворот к цели
        back := RandF(35, 110)
        wx := x0 - ux * back - uy * RandF(-45, 45)
        wy := y0 - uy * back + ux * RandF(-45, 45)
        wx := Max(RX, Min(RX + RW, wx))
        wy := Max(RY, Min(RY + RH, wy))
        d1 := dur * RandF(0.22, 0.32)
        MoveSeg(Round(wx), Round(wy), d1, 0)
        if (!Running)
            return
        pz := RandInt(40, 140)
        Sleep, %pz%
        MoveSeg(tx, ty, Max(150, dur - d1 - pz), 0)
    } else if (dist > 90 && roll < 0.32) {
        ; лёгкий перелёт и возврат, без остановки между фазами
        over := RandF(8, 20)
        ox := tx + ux * over - uy * RandF(-6, 6)
        oy := ty + uy * over + ux * RandF(-6, 6)
        MoveSeg(Round(ox), Round(oy), dur * 0.84, 1)
        if (!Running)
            return
        MoveSeg(tx, ty, Max(120, dur * 0.16), 0)
    } else {
        MoveSeg(tx, ty, dur, 0)
    }
}

; Один отрезок: путь WindMouse, воспроизведение по времени с плавным профилем скорости,
; медленным "плаванием" руки и редкими подёргиваниями. mode 1 = не тормозить в конце.
MoveSeg(xe, ye, dur, mode) {
    global Running, Scl
    MouseGetPos, xs0, ys0
    grav := RandF(7.0, 11.0)
    wnd := RandF(2.2, 4.5)
    mstep := RandF(10.0, 17.0) * Scl
    tarea := RandF(9.0, 15.0) * Scl
    xs := xs0
    ys := ys0
    vx := 0
    vy := 0
    wx := 0
    wy := 0
    axs := [xs0]
    ays := [ys0]
    iter := 0
    while (iter < 500) {
        iter += 1
        gx := xe - xs
        gy := ye - ys
        gd := Sqrt(gx * gx + gy * gy)
        if (gd < 4 * Scl)
            break
        wmax := (wnd < gd) ? wnd : gd
        if (gd >= tarea) {
            wx := wx / 1.7320508 + (RandF(0.0, 1.0) * (wmax * 2 + 1) - wmax) / 2.2360680
            wy := wy / 1.7320508 + (RandF(0.0, 1.0) * (wmax * 2 + 1) - wmax) / 2.2360680
        } else {
            wx := wx / 1.7320508
            wy := wy / 1.7320508
            if (mstep < 3)
                mstep := RandF(3.0, 6.0)
            else
                mstep := mstep / 2.2360680
        }
        vx += wx + grav * gx / gd
        vy += wy + grav * gy / gd
        vm := Sqrt(vx * vx + vy * vy)
        if (vm > mstep) {
            rd := mstep / 2 + RandF(0.0, 1.0) * mstep / 2
            vx := vx / vm * rd
            vy := vy / vm * rd
        }
        xs += vx
        ys += vy
        axs.Push(xs)
        ays.Push(ys)
    }
    axs.Push(xe)
    ays.Push(ye)

    m := axs.MaxIndex()
    cum := [0]
    total := 0
    ci := 1
    while (ci < m) {
        cdx := axs[ci + 1] - axs[ci]
        cdy := ays[ci + 1] - ays[ci]
        total += Sqrt(cdx * cdx + cdy * cdy)
        cum.Push(total)
        ci += 1
    }
    if (total < 2 || dur < 40) {
        MouseMove, %xe%, %ye%, 0
        return
    }

    stallAt := (mode = 0 && total > 150 && RandF(0.0, 1.0) < 0.25) ? RandF(0.30, 0.70) : 2
    stallDone := false
    skew := RandF(0.88, 1.20)
    nsx := 0
    nsy := 0
    twx := 0
    twy := 0
    idx := 1
    t0 := A_TickCount
    Loop {
        if (!Running)
            return
        k := (A_TickCount - t0) / dur
        if (k >= 1)
            break
        if (!stallDone && k >= stallAt) {
            stallDone := true
            hold := RandInt(40, 140)
            Sleep, %hold%
            t0 += hold
            continue
        }
        kk := k ** skew
        if (mode = 1)
            s := Sm(0.7 * kk) / 0.83692
        else
            s := Sm(kk)
        pd := s * total
        while (idx < m - 1 && cum[idx + 1] < pd)
            idx += 1
        sg := cum[idx + 1] - cum[idx]
        fr := (sg > 0) ? (pd - cum[idx]) / sg : 0
        if (fr > 1)
            fr := 1
        bx := axs[idx] + (axs[idx + 1] - axs[idx]) * fr
        by := ays[idx] + (ays[idx + 1] - ays[idx]) * fr
        nsx := (nsx + RandF(-0.9, 0.9)) * 0.93
        nsy := (nsy + RandF(-0.9, 0.9)) * 0.93
        if (RandF(0.0, 1.0) < 0.015) {
            twx := RandF(-3.0, 3.0)
            twy := RandF(-3.0, 3.0)
        }
        twx *= 0.6
        twy *= 0.6
        env := Sin(k * 3.14159)
        MouseMove, % Round(bx + (nsx + twx) * env), % Round(by + (nsy + twy) * env), 0
    }
    MouseMove, %xe%, %ye%, 0
}

; Блуждание по области рубашки (как будто разглядывает цифры)
WanderHuman(dur) {
    global Running, RX, RY, RW, RH
    pts := (RandF(0.0, 1.0) < 0.4) ? 2 : 1
    per := dur / pts
    Loop, %pts% {
        if (!Running)
            return
        wx := RX + RandF(0.08, 0.92) * RW
        wy := RY + RandF(0.08, 0.92) * RH
        MoveSeg(Round(wx), Round(wy), per * RandF(0.70, 0.90), 0)
        Sleep, % RandInt(30, 120)
    }
}

; Пауза до дедлайна: иногда блуждает по рубашке, иначе лёгкое подрагивание на месте
IdleHuman(deadline) {
    global Running
    left := deadline - A_TickCount
    if (left > 1200 && RandF(0.0, 1.0) < 0.28)
        WanderHuman(left * 0.75)
    left := deadline - A_TickCount
    if (left > 0 && Running)
        HoverHuman(left, 0.3)
    SleepUntil(deadline)
}

; Зависание над точкой: курсор в основном неподвижен, изредка один крошечный сдвиг
HoverHuman(ms, f) {
    global Running
    t0 := A_TickCount
    while (Running && A_TickCount - t0 < ms) {
        if (RandF(0.0, 1.0) < 0.12) {
            MouseGetPos, hx, hy
            MouseMove, % hx + RandInt(-1, 1), % hy + RandInt(-1, 1), 0
        }
        Sleep, % RandInt(60, 180)
    }
}

RandInt(a, b) {
    Random, r, %a%, %b%
    return r
}

SleepRnd(minMs, maxMs) {
    global Running
    Random, total, %minMs%, %maxMs%
    waited := 0
    while (waited < total && Running) {
        Sleep, 100
        waited += 100
    }
}

; =====================================================================
; ПОИСК ЦИФР: белые цифры -> кружки -> распознавание по шаблонам шрифта игры
; (без OCR). Каждая цифра сравнивается с эталонами 0-9, а числа 1..20
; назначаются кружкам так, чтобы каждое число использовалось один раз.
; =====================================================================
InitTemplates() {
    global TplF, TplW
    t := []
    t.Push("0,22,78,71,13,0,3,96,84,92,88,2,33,64,3,5,72,21,54,24,0,0,39,45,70,13,0,0,24,58,70,11,0,0,23,60,65,16,0,0,30,51,45,40,0,0,53,33,16,86,19,28,88,8,2,74,100,100,58,0")
    t.Push("58,89,91,91,72,44,40,66,73,82,82,56,0,2,15,40,75,55,0,2,15,40,75,55,0,2,15,40,76,55,0,4,18,42,76,55,0,2,16,41,76,55,0,2,15,40,75,55,0,2,15,40,75,55,0,2,14,39,75,55")
    t.Push("0,55,85,76,21,0,45,95,76,88,96,9,23,6,0,8,78,36,0,0,0,2,67,41,0,0,0,8,76,32,0,0,8,86,38,1,0,9,68,62,0,0,0,68,89,8,0,0,11,87,33,0,0,0,51,100,100,100,100,75")
    t.Push("42,92,92,92,89,47,28,68,68,70,99,50,0,0,0,27,70,7,0,0,12,73,19,0,0,7,60,74,0,0,0,0,0,8,89,60,0,0,0,0,51,73,1,0,0,0,54,74,68,32,1,8,89,59,24,100,100,100,73,9")
    t.Push("0,0,0,54,33,0,0,0,16,84,14,0,0,0,59,55,0,0,0,15,77,6,0,0,0,63,52,3,11,0,44,50,0,34,62,0,82,100,100,100,100,63,18,30,30,60,76,13,0,0,0,34,61,0,0,0,0,34,61,0")
    t.Push("0,82,91,91,88,27,3,90,74,67,64,16,7,72,13,0,0,0,9,66,10,0,0,0,16,71,36,16,0,0,0,0,0,7,80,53,0,0,0,0,39,60,0,0,0,0,42,61,55,45,3,11,84,47,16,100,100,100,81,6")
    t.Push("0,3,38,90,79,4,0,82,100,70,79,18,10,83,25,0,0,0,31,43,1,0,0,0,49,30,8,30,12,0,49,84,25,0,36,56,43,52,2,0,11,72,27,57,4,0,13,69,5,90,42,3,53,44,0,59,100,100,98,4")
    t.Push("58,91,91,91,91,63,72,70,67,67,86,70,70,3,0,6,75,52,36,0,0,12,86,26,0,0,0,30,75,8,0,0,5,69,20,0,0,0,25,74,0,0,0,2,57,64,0,0,0,22,82,42,0,0,0,48,86,20,0,0")
    t.Push("0,40,78,76,35,0,16,98,78,82,99,9,42,34,0,0,41,36,43,22,0,0,31,42,21,66,9,14,75,18,39,65,8,12,69,34,69,9,0,0,14,63,71,7,0,0,14,65,51,53,1,5,61,40,4,98,100,100,96,0")
    t.Push("0,53,84,56,8,0,20,94,74,92,90,0,63,20,0,9,70,14,70,3,0,2,48,32,70,14,0,6,65,48,0,80,100,72,58,48,0,0,0,0,31,34,0,0,0,6,65,18,2,1,0,64,92,0,22,100,100,92,39,0")
    Loop, 10
        TplF[A_Index] := StrSplit(t[A_Index], ",")
    TplW := StrSplit("9.3,4.5,8.6,8.2,9.7,8.5,9.0,8.3,9.0,9.0", ",")
}

ScanPoints() {
    global RX, RY, RW, RH, N, Px, Py, MissingStr, DebugStr, ClCount, MaxCost, DebugSave
    DebugStr := ""
    t0 := A_TickCount
    found := []
    Loop, %N% {
        found[A_Index] := 0
        Px[A_Index] := 0
        Py[A_Index] := 0
    }

    pBits := 0
    hbm := CaptureDIB(RX, RY, RW, RH, pBits)
    if (!hbm || !pBits) {
        Status("CAPTURE FAILED")
        return -1
    }
    Status("Scanning: capture ok (" . (A_TickCount - t0) . " ms), looking for digits...")
    clusters := FindClusters(pBits, RW, RH)
    Status("Scanning: digits found in " . (A_TickCount - t0) . " ms, matching...")
    ClCount := clusters.MaxIndex() ? clusters.MaxIndex() : 0
    DebugStr .= "screen " . A_ScreenWidth . "x" . A_ScreenHeight . "  region " . RX . "," . RY . " " . RW . "x" . RH . "`n"
    DebugStr .= "clusters: " . ClCount . "`n"

    ; стоимость (непохожесть) каждого числа для каждого кружка
    items := []
    for ci, c in clusters {
        if (c.bl.MaxIndex() = 1) {
            cs := BlobCosts(pBits, RW, c.bl[1])
            num := 1
            while (num <= 9) {
                items.Push({cost: cs[num + 1], ci: ci, n: num})
                num++
            }
        } else {
            a := c.bl[1]
            b2 := c.bl[2]
            if (a.x0 > b2.x0) {
                tmp := a
                a := b2
                b2 := tmp
            }
            c1 := BlobCosts(pBits, RW, a)
            c2 := BlobCosts(pBits, RW, b2)
            num := 10
            while (num <= N) {
                items.Push({cost: c1[num // 10 + 1] + c2[Mod(num, 10) + 1], ci: ci, n: num})
                num++
            }
        }
    }
    if (DebugSave)
        SavePng(hbm, A_ScriptDir . "\scan_region.png")
    DllCall("DeleteObject", "Ptr", hbm)

    bestC := {}
    for k, it in items {
        if (!bestC.HasKey(it.ci) || it.cost < bestC[it.ci].cost)
            bestC[it.ci] := it
    }
    for ci, it in bestC {
        c := clusters[ci]
        DebugStr .= "cluster " . ci . " at (" . Round(RX + c.cx) . "," . Round(RY + c.cy) . ") size=" . (c.x1 - c.x0 + 1) . "x" . (c.y1 - c.y0 + 1) . " digits=" . c.bl.MaxIndex() . " best=" . it.n . " cost=" . Round(it.cost) . "`n"
    }

    ; жадное назначение: сначала самые похожие пары (кружок, число)
    usedC := {}
    usedN := {}
    cnt := 0
    Loop, %N% {
        bestCost := 999999999
        bi := 0
        for k, it in items {
            if (usedC[it.ci] || usedN[it.n])
                continue
            if (it.cost < bestCost) {
                bestCost := it.cost
                bi := k
            }
        }
        if (!bi || bestCost > MaxCost)
            break
        it := items[bi]
        usedC[it.ci] := 1
        usedN[it.n] := 1
        c := clusters[it.ci]
        Px[it.n] := Round(RX + c.cx)
        Py[it.n] := Round(RY + c.cy)
        found[it.n] := 1
        cnt++
        DebugStr .= "number " . it.n . " at (" . Px[it.n] . "," . Py[it.n] . ") cost=" . Round(bestCost) . "`n"
    }

    MissingStr := ""
    missCnt := 0
    lastMiss := 0
    Loop, %N% {
        if (!found[A_Index]) {
            MissingStr .= A_Index . " "
            missCnt++
            lastMiss := A_Index
        }
    }

    ; Красная точка закрывает цифру — если не хватает ровно одной, берём позицию точки
    if (missCnt = 1) {
        if (FindRedDot(rdx, rdy)) {
            Px[lastMiss] := rdx
            Py[lastMiss] := rdy
            found[lastMiss] := 1
            cnt++
            MissingStr := ""
            DebugStr .= "red dot used for " . lastMiss . " (" . rdx . "," . rdy . ")`n"
        }
    }
    DebugStr .= "missing: " . MissingStr . "`n"
    DebugStr .= "time: " . (A_TickCount - t0) . " ms`n"
    return cnt
}

; Признаки одной цифры -> стоимость сравнения с шаблонами 0..9 (индекс = цифра + 1)
BlobCosts(pBits, W, blob) {
    global GW, GH, TplF, TplW, Scl
    bw := blob.x1 - blob.x0 + 1
    bh := blob.y1 - blob.y0 + 1
    f := []
    cy := 0
    while (cy < GH) {
        sy := blob.y0 + Floor((cy + 0.5) * bh / GH)
        cx := 0
        while (cx < GW) {
            sx := blob.x0 + Floor((cx + 0.5) * bw / GW)
            v := NumGet(pBits + 0, (sy * W + sx) * 4, "UInt")
            r := (v >> 16) & 255
            g := (v >> 8) & 255
            bl := v & 255
            br := (r + g + bl) // 3
            if ((Max(r, g, bl) - Min(r, g, bl)) >= 50 || br <= 110)
                gv := 0
            else if (br >= 235)
                gv := 100
            else
                gv := Round((br - 110) * 100 / 125)
            f.Push(gv)
            cx++
        }
        cy++
    }
    wn := bw / Scl
    costs := []
    d := 1
    while (d <= 10) {
        tf := TplF[d]
        s := 0
        i := 1
        while (i <= 60) {
            s += Abs(f[i] - tf[i])
            i++
        }
        s += 4 * Abs(wn - TplW[d])
        costs.Push(s)
        d++
    }
    return costs
}

FindRedDot(ByRef cx, ByRef cy) {
    global RX, RY, RW, RH, RedVar
    x2 := RX + RW
    y2 := RY + RH
    PixelSearch, fx, fy, %RX%, %RY%, %x2%, %y2%, 0xFF0000, %RedVar%, Fast RGB
    if (ErrorLevel)
        return false
    h := 1
    Loop, 40 {
        yy := fy + h
        PixelSearch, qx, qy, %fx%, %yy%, %fx%, %yy%, 0xFF0000, %RedVar%, Fast RGB
        if (ErrorLevel)
            break
        h++
    }
    cx := fx
    cy := Round(fy + h / 2)
    return true
}

; ---------- Захват региона экрана в DIB (с доступом к пикселям) ----------
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

; ---------- Находит кружки по белым цифрам ----------
FindClusters(pBits, W, H) {
    global Scl
    VarSetCapacity(mask, W * H, 0)
    cand := []
    idx := 0
    Loop, %H% {
        Loop, %W% {
            v := NumGet(pBits + 0, idx * 4, "UInt")
            r := (v >> 16) & 255
            g := (v >> 8) & 255
            b := v & 255
            if ((r + g + b) > 450) {
                if (Max(r, g, b) - Min(r, g, b) < 50) {
                    NumPut(1, mask, idx, "UChar")
                    cand.Push(idx)
                }
            }
            idx++
        }
    }

    minH := 8 * Scl
    maxH := 20 * Scl
    minW := 2 * Scl
    maxW := 16 * Scl
    minCnt := 8 * Scl * Scl
    blobs := []
    for i, start in cand {
        if (NumGet(mask, start, "UChar") != 1)
            continue
        NumPut(2, mask, start, "UChar")
        stack := [start]
        x0 := W
        y0 := H
        x1 := -1
        y1 := -1
        cnt := 0
        while (stack.MaxIndex()) {
            cur := stack.Pop()
            cy := cur // W
            cx := cur - cy * W
            if (cx < x0)
                x0 := cx
            if (cx > x1)
                x1 := cx
            if (cy < y0)
                y0 := cy
            if (cy > y1)
                y1 := cy
            cnt++
            dy := -1
            while (dy <= 1) {
                dx := -1
                while (dx <= 1) {
                    nx := cx + dx
                    ny := cy + dy
                    if (nx >= 0 && nx < W && ny >= 0 && ny < H) {
                        ni := ny * W + nx
                        if (NumGet(mask, ni, "UChar") = 1) {
                            NumPut(2, mask, ni, "UChar")
                            stack.Push(ni)
                        }
                    }
                    dx++
                }
                dy++
            }
        }
        bh := y1 - y0 + 1
        bw := x1 - x0 + 1
        if (bh >= minH && bh <= maxH && bw >= minW && bw <= maxW && cnt >= minCnt)
            blobs.Push({x0: x0, y0: y0, x1: x1, y1: y1})
    }

    clusters := []
    for i, bb in blobs {
        bcx := (bb.x0 + bb.x1) / 2
        bcy := (bb.y0 + bb.y1) / 2
        merged := false
        for j, c in clusters {
            if (c.bl.MaxIndex() < 2 && Abs(bcx - c.cx) <= 16 * Scl && Abs(bcy - c.cy) <= 6 * Scl) {
                c.bl.Push(bb)
                c.x0 := Min(c.x0, bb.x0)
                c.y0 := Min(c.y0, bb.y0)
                c.x1 := Max(c.x1, bb.x1)
                c.y1 := Max(c.y1, bb.y1)
                c.cx := (c.x0 + c.x1) / 2
                c.cy := (c.y0 + c.y1) / 2
                merged := true
                break
            }
        }
        if (!merged)
            clusters.Push({x0: bb.x0, y0: bb.y0, x1: bb.x1, y1: bb.y1, cx: bcx, cy: bcy, bl: [bb]})
    }

    res := []
    resN := 0
    for i, c in clusters {
        if ((c.x1 - c.x0 + 1) <= 34 * Scl && resN < 60) {
            res.Push(c)
            resN++
        }
    }
    return res
}

; ---------- Сохранение HBITMAP в PNG (для диагностики) ----------
SavePng(hbm, path) {
    VarSetCapacity(si, 24, 0)
    NumPut(1, si, 0, "UInt")
    DllCall("LoadLibrary", "Str", "gdiplus")
    tok := 0
    DllCall("gdiplus\GdiplusStartup", "Ptr*", tok, "Ptr", &si, "Ptr", 0)
    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", pBmp)
    VarSetCapacity(clsid, 16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", &clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "WStr", path, "Ptr", &clsid, "Ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", tok)
}
