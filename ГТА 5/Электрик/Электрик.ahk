; =====================================================================
; ЭЛЕКТРИК (мини-игра WATT)  -  AutoHotkey v1
; v3: если молнии нет на миникарте - крутим камеру и ищем (BoltSearch).
; v2: навигация - поворот камерой вместо змейки A/D, подсказка E над маркером, обход препятствий.
; F6 старт/стоп (между раундами скрипт сам ждёт новое окно WATT) | F7 выход | F9 ходьба к молнии вкл/выкл | F8 диагностика (файл electric_debug.txt + electric_scan.bmp)
; Поиск стартует только когда в центре видно "0%" (RequireZero). Файл сохранять в UTF-8 с BOM.
; =====================================================================
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
; НАСТРОЙКИ (все координаты заданы для 1920x1080 и пересчитываются
; через Px()/Py()/Sc относительно центра экрана; масштаб по высоте)
; =====================================================================
; --- поддерживаемые разрешения / масштаб Windows
global SupportedRes := "1920x1080,2560x1440,1600x900,1366x768"
global MeasuredRes  := "1920x1080"     ; координаты сняты со скриншота только на этом разрешении

; --- геометрия окна WATT (база 1080p, пиксели со скриншота)
global RingCX   := 960        ; центр кольца
global RingCY   := 551
global ScanR    := 150        ; радиус, по которому водим мышь
global DotX0    := 934.5      ; ожидаемый центр 1-й точки "СИГНАЛ" (на скане F8 было 924, y=600)
global DotStep  := 10.5       ; шаг между точками
global DotY     := 608.5
global DotBandX  := 30        ; ряд точек в игре смещается (~10 px): ищем в полосе вокруг ожидаемого места
global DotBandUp := 40        ; полоса вверх от DotY (на скане F8 точки были на ~25 px выше ожидаемого места)
global DotBandDn := 14        ; полоса вниз от DotY
global LedX     := 1263.5     ; оранжевый индикатор в углу окна (признак, что окно открыто)
global LedY     := 189.5

; --- допуски цвета (разность R-B)
global LitMin   := 40         ; точка горит, если R-B не меньше (погасшая ~0, горящая 100..215)
global LitFull  := 215        ; R-B самой яркой точки (только для тонкой оценки яркости)
global LedMin   := 120        ; R-B пикселя индикатора (на скрине ~218)
global RequireZero := 1       ; 1 = начинать поиск только когда в центре видно "0%" (экран загрузки игнорируется); 0 = как раньше
global ZeroX0 := 895          ; прямоугольник, где ищем текст "0%" (база 1080p): с запасом, т.к. положение панели плавает
global ZeroY0 := 480
global ZeroW  := 150
global ZeroH  := 105
global ZeroWhiteMin := 600    ; белых пикселей текста "0%" (на скане ~1750)
global ZeroWhiteMax := 3200
global ZeroOrangeMax := 150   ; оранжевых пикселей: на экране загрузки логотип WATT даёт ~3000, у "0%" почти 0
global ZeroExtMin := 45       ; ширина белого текста, px: "0%" ~71, а логотип/"100%" заметно шире
global ZeroExtMax := 95
global LedGreenMin := 60      ; G-R пикселя зелёного индикатора окна "Успех" (на скрине ~117)

; --- ходьба к жёлтой молнии по миникарте (WASD). Координаты 1080p, привязка к левому нижнему углу экрана
global NavEnabled := 1        ; 1 = пока окна WATT нет, бежим к молнии на миникарте; F9 = вкл/выкл
global MapX0 := 30            ; прямоугольник карты (без нижней полосы со значками)
global MapY0 := 862
global MapX1 := 346
global MapY1 := 1038
global PlayerX := 186         ; где на карте стоит белая стрелка игрока (на скрине 186,987)
global PlayerY := 987
global BoltMinPx := 26        ; молния-цель: жёлтых пикселей не меньше (у неё ~32; у молнии внутри треугольника ~20 - её игнорируем)
global BoltMinW  := 7
global BoltMinH  := 8
global NavDead   := 3         ; (не используется напрямую) мёртвая зона, px карты
global NavDeadOn  := 6        ; начать жать клавишу, когда смещение по оси больше этого (px карты)
global NavDeadOff := 2        ; отпустить клавишу, когда смещение стало меньше этого (гистерезис - против "змейки")
global NavCone    := 0.30     ; A/D жмём, только если молния отклонилась от курса больше ~17 градусов (dx > |dy| * NavCone)
global KeyHoldMs  := 220      ; A/D не отпускаем раньше этого времени после нажатия, мс
global CamTurnPx  := 140      ; на сколько px двигаем мышь за один поворот камеры, когда застряли (подбирается под чувствительность)
global CamTries   := 8        ; сколько поворотов камеры пробуем, чтобы выбраться
global MarkStuckMs := 2500    ; маркер виден, но не приближается столько мс = застряли
global ArriveR   := 7         ; ближе этого расстояния (px карты) считаем, что добежали
global StuckMs   := 1500      ; если за это время ближе не стали - "застряли": прыжок + шаг вбок
global UseSprint := 1         ; 1 = держим Shift при беге
global InteractKey := "e"     ; клавиша, которой запускается мини-игра у оранжевого маркера; "" = не жать
; --- оранжевый маркер (шеврон с гаечным ключом) в мире: когда он виден на экране, идём к нему и жмём E
global MarkX0 := 100          ; область поиска маркера на экране (база 1080p, от центра): без HUD справа и миникарты
global MarkY0 := 130
global MarkX1 := 1620
global MarkY1 := 960
global MarkStride := 6        ; шаг выборки пикселей при поиске (больше = быстрее, но грубее)
global MarkMinSamples := 12   ; минимум найденных оранжевых выборок, чтобы считать маркером (у шеврона на скрине их ~230)
global MarkDeadX := 28        ; допуск по горизонтали от центра экрана, px (внутри - идём прямо)
global MarkPressW := 110      ; ширина маркера, с которой начинаем жать E на ходу
global MarkStopW := 260       ; ширина маркера, с которой останавливаемся и жмём E (подбирается: ближе = шире)
global NoBoltKeepMs := 2500   ; если молнии на карте не видно (например под стрелкой), продолжаем бег столько мс

; --- поиск молнии вращением камеры: молнии нет на миникарте и маркера нет -> крутим камеру на месте и смотрим миникарту
global BoltSearch := 1            ; 1 = крутить камеру и искать молнию; 0 = как раньше (стоим и ждём)
global BoltSearchStepDeg := 30    ; шаг поворота, градусы (когда камера откалибрована)
global BoltSearchStepCnt := 140   ; шаг поворота в тиках мыши, если камера ещё не откалибрована (подбирается в игре)
global BoltSearchSteps := 12      ; шагов за один проход (12 x 30 = полный круг)
global BoltSearchSettleMs := 280  ; пауза после шага: миникарта догоняет камеру, мс
global BoltSearchPauseMs := 1500  ; пауза после прохода, в котором молнию не нашли, мс

; --- v2: навигация камерой / подсказка E / обход препятствий
global CamSteer := 1          ; 1 = рулим камерой (мышь) и жмём только W: бег по прямой; сама калибруется. 0 = старый режим A/D
global CamStep := 60           ; тиков мыши за один шаг поворота (больше = быстрее вращение)
global CamStepMs := 2         ; пауза между шагами, мс
global CalTurnCnt := 120      ; на сколько "тиков" мыши крутим камеру при калибровке (по минимапе считаем градусы на тик)
global AimDeadDeg := 6        ; ошибка курса до молнии (градусы), в пределах которой камеру не трогаем
global AimGain := 1.0         ; доля ошибки, исправляемая за один поворот (меньше = плавнее, но медленнее)
global AimMaxCnt := 2500       ; максимум тиков мыши за один поворот
global AimCooldownMs := 130    ; пауза между поворотами (минимапа/камера отстают)
global MarkDegPerPx := 0.045  ; градусов поворота камеры на 1 px (1080p) смещения маркера от курса (~90 градусов на 1920 px)
global MarkSlowW := 130       ; ширина маркера (px), с которой переходим с бега на шаг
global CharX := 815           ; x персонажа на экране (база 1080p, на скрине ~815); курс бега сходится к центру экрана 960
global EFallbackMs := 3000    ; маркер вплотную, а подсказки E не видно столько мс - жмём E вслепую
global StillDiffMax := 1.3    ; средняя разница кадров фона ниже этого при зажатой W = мы стоим
global StillMs := 450         ; стоим столько мс при зажатой W = упёрлись в препятствие
global ClearMin := 160
; --- v4: прыжок (пробел), когда упёрлись
global JumpOn := 1
global JumpKeyDn := "{sc039 down}"
global JumpKeyUp := "{sc039 up}"
global JumpLast := 0
global JumpTries := 0
global FloorLumMax := 175   ; v3: светлый бетон тоже пол (было 130)
global FloorFlat := 22      ; v3: допуск неровности пола, трещины бетона (было 14)        ; (для F8) глубина свободного пола в полосе: меньше = препятствие рядом
global CamDpc := 0            ; градусов поворота вправо на +1 тик мыши (определяется калибровкой; 0 = не определено)
global CamCalDone := 0
global CamDpc0 := 0
global PendCnt := 0
global PendAng := 0
global PendT := 0
global NearSince := 0
global NearL := 0
global NearR := 0
global AheadHits := 0
global LastAheadT := 0
global LastProact := 0
global ProactiveAvoid := 1    ; 1 = объезжать препятствие заранее (по свободному полу слева/справа от персонажа), не дожидаясь упора
global NavLastDist := 999
global OrbitLevel := 0
global OrbitLast := 0
global OrbitSide := 1
global CamCalMs := 0
global LastTurnT := 0
global StillSince := 0
global SigPrev := []
global DetourLevel := 0
global DetourLast := 0
global DetourSide := 1
global DetourHoldUntil := 0
; --- v2: камера по клавише C, обход точки по миникарте
global CamResetOn := 1
global CamResetKeyDn := "{sc02E down}"
global CamResetKeyUp := "{sc02E up}"
global CamResetEveryMs := 7000
global LastCamReset := 0
global LastCamMoveT := 0
global CircRBase := 14
global CircR := 14
global CircSide := 1
global CircLevel := 0
global CircLast := 0
global CircMaxMs := 5000
global MarkScanSteps := 8       ; v5: шагов поворота камеры при поиске маркера (8 x 45 = круг)
global MarkScanDeg := 45
global MarkScanSettleMs := 260  ; пауза после шага, мс
global CircScanEveryMs := 1800  ; при обходе точки: как часто останавливаться и осматриваться, мс
global MarkSeenT := 0
global MarkSeenW := 0
global MarkNearSince := 0
global MarkSeenX := 0
global MarkSeenY := 0
global BlindE := 0            ; 1 = разрешить жать E вслепую (без подсказки E на экране). По умолчанию 0: E только когда подсказка видна

; --- пороги по числу горящих точек
global PressMin := 5          ; при стольких горящих точках зажимаем ЛКМ (при 4 НЕ жмём)
global FullMin  := 5          ; все точки: дальше не уточняем, мышь замирает
global LockOnMin := 4         ; обход круга прерывается и начинается наведение только при 4 точках (5 бывает только рядом с 4; 3 и меньше - ещё далеко, не цепляемся)
global LockHits  := 1         ; сколько подряд чтений с LockOnMin+ точек нужно, чтобы остановить обход
global KeepMin  := 4          ; ниже этого (дольше HoldBadMs) отпускаем и ищем заново
global MinSignal := 1         ; меньше - сигнала нет

; --- поиск
global SweepStep := 30        ; шаг обхода круга, градусы
global MinStep   := 2       ; минимальный шаг уточнения, градусы
global MoveBaseMs  := 14      ; время перехода: база, мс
global MoveMsPerPx := 0.4     ; + мс на каждый пиксель пути (в пикселях 1080p)
global GlideEnabled := 1      ; 1 = плавный непрерывный обход круга (без остановок); 0 = старый обход "шагами"
global GlideDps   := 260      ; скорость обхода, градусов в секунду
global GlideLagMs := 50       ; задержка игры: во столько мс точки отстают от мыши (подбирается в игре)
global RefineGain := 0.15    ; на сколько должен вырасти счёт, чтобы шаг считался улучшением (мерцание яркости точек ~0.1 - не в счёт)
global RefineMaxMs := 900     ; максимум времени на точное наведение, потом сдаёмся и ищем заново
global RefineIterMax := 16
global RefineShrink := 0.75   ; после удачного шага следующий шаг меньше (сходимость вместо блуждания)
global RefineStart := 10      ; первый шаг точного наведения, градусы (при GlideEnabled = 1)
global SweepStepRndMin := 0.7 ; шаг обхода каждый раз случайный: SweepStep * (от..до)
global SweepStepRndMax := 1.1
global RadiusJitter := 0.08   ; радиус круга на каждый поиск случайный (+-8%); 0 = всегда ScanR
global OvershootChance := 0.15 ; шанс небольшого перелёта и возврата при длинном переходе
global HesitateChance := 0.02 ; шанс короткой "задумчивости" после перехода
global HesitateMin := 150
global HesitateMax := 350
global ReactMin := 60        ; "реакция" после смены цели, мс
global ReactMax := 200
global ResumeDelayMin := 100  ; пауза после появления "0%", мс
global ResumeDelayMax := 250
global DwellMin  := 30        ; пауза после перехода перед чтением точек, мс
global DwellMax  := 50
global PressDelayMin := 30    ; пауза перед нажатием ЛКМ, мс
global PressDelayMax := 80

; --- удержание / завершение
global HoldBadMs   := 250     ; сколько мс точек мало, прежде чем отпустить
global LostMs      := 1500    ; индикатор не виден столько мс = окно закрыто
global NoSignalMax := 5       ; столько полных кругов без сигнала - остановка с подсказкой

; --- служебное
global KeyDown := {}
global KeyTime := {}
global StuckCount := 0
global StuckLast := 0
global MarkBestW := 0
global MarkProg := 0
global NavBest := 0
global NavProg := 0
global NavLastStatus := 0
global NavLastInteract := 0
global NavLastBolt := 0
global NearTries := 0
global Running := false
global Busy    := false
global Held    := false
global Armed   := false      ; "0%" уже увидели в этом раунде - можно искать и ловить сигнал
global PollMin := 1           ; пауза между опросами точек при обходе, мс (было 5-9)
global PollMax := 3
global HoldPollMin := 15      ; пауза между опросами при удержании, мс (было 50-90)
global HoldPollMax := 30
global LedSeen := 0
global Sc      := A_ScreenHeight / 1080
global CurR    := ScanR

CheckEnv()

Gui, St:+AlwaysOnTop -Caption +ToolWindow +E0x20 +LastFound
Gui, St:Color, 000000
Gui, St:Font, s16 bold, Arial
Gui, St:Add, Text, vStTxt cLime w900, READY: F6 start | F7 exit | F8 debug | F9 nav
Gui, St:Show, x20 y20 NoActivate
WinSet, Transparent, 210

OnError("ShowErr")
OnExit, DoExit
if (A_ScreenWidth . "x" . A_ScreenHeight != MeasuredRes)
    Status("READY, but " . A_ScreenWidth . "x" . A_ScreenHeight . " is NOT calibrated: press F8 and check")
return

DoExit:
    ReleaseKeys()
    if (Held)
        Click, Up
    DllCall("winmm\timeEndPeriod", "UInt", 1)
ExitApp

ShowErr(e) {
    global Running, Busy, Held
    Running := false
    Busy := false
    ReleaseKeys()
    if (Held) {
        Click, Up
        Held := false
    }
    Status("ERROR line " . e.Line . ": " . e.Message . " " . e.Extra)
    return true
}

Status(txt) {
    GuiControl, St:, StTxt, %txt%
    Sleep, 1
}

; Проверка разрешения и масштаба Windows при запуске
CheckEnv() {
    global SupportedRes
    res := A_ScreenWidth . "x" . A_ScreenHeight
    dpi := A_ScreenDPI
    if (!InStr("," . SupportedRes . ",", "," . res . ",")) {
        MsgBox, 16, Электрик, % "Разрешение экрана " . res . " не поддерживается.`n`nПоддерживаются: 1920x1080, 2560x1440, 1600x900, 1366x768.`nСкрипт не запущен."
        ExitApp
    }
    if (dpi != 96 && dpi != 120 && dpi != 144) {
        MsgBox, 16, Электрик, % "Масштаб Windows " . Round(dpi * 100 / 96) . "% не поддерживается.`n`nПоддерживаются: 100%, 125%, 150%.`nСкрипт не запущен."
        ExitApp
    }
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
        Status("RUNNING (F6 = stop)")
        SetTimer, DoWork, -10
    }
return

F7::ExitApp

F8::
    DebugDump()
return

F9::
    NavEnabled := !NavEnabled
    if (!NavEnabled)
        ReleaseKeys()
    Status("NAV " . (NavEnabled ? "ON" : "OFF"))
return

; =====================================================================
; ОСНОВНОЙ ЦИКЛ
; =====================================================================
DoWork:
    Busy := true
    Armed := false
    CamCalDone := 0
    DetourLevel := 0
    StillSince := 0
    MarkSeenT := 0
    LedSeen := Now()
    noSig := 0
    endMsg := "STOPPED"
    while (Running) {
        ; окно WATT не открыто (закрыто / "Успех") - ничего не делаем, ждём новое окно
        if (!WaitForWatt())
            break
        Status("Searching signal...")
        r := Seek()
        if (r = "stopped")
            break
        if (r = "lost") {
            ReleaseLmb()
            noSig := 0
            continue
        }
        if (r = "miss") {
            ; сигнал был, но до 5 точек не дотянули - пробуем снова (счётчик "нет сигнала" не растёт)
            ReleaseLmb()
            Sleep, % RandInt(30, 80)
            continue
        }
        if (r = "none") {
            ReleaseLmb()
            noSig++
            if (noSig >= NoSignalMax) {
                endMsg := "No signal dots found: press F8 and send electric_debug.txt + electric_scan.bmp"
                break
            }
            Sleep, % RandInt(150, 400)
            continue
        }
        noSig := 0
        Status("HOLD (F6 = stop)")
        r := Hold()
        if (r = "lost") {
            noSig := 0
            continue
        }
        if (r = "dropped") {
            Status("Target changed - searching again")
            Sleep, % RandInt(ReactMin, ReactMax)
        }
    }
    ReleaseLmb()
    ReleaseKeys()
    Running := false
    Busy := false
    Status(endMsg)
return

; Ждёт новый раунд: окно WATT (оранжевый индикатор) И "0%" в центре (не экран загрузки).
; Пока раунд идёт и "0%" уже был увиден (Armed) - возвращается сразу, без пауз.
WaitForWatt() {
    global Running, LedSeen, ResumeDelayMin, ResumeDelayMax, RequireZero, Armed, NavEnabled
    if (Armed) {
        if (WindowAlive())
            return Running
        Armed := false
    }
    last := ""
    Loop {
        if (!Running)
            return false
        if (LedOn()) {
            ReleaseKeys()
            if (!RequireZero) {
                Sleep, 150
                if (LedOn())
                    break
            } else {
                if (ZeroOn()) {
                    Sleep, 35
                    if (ZeroOn() && LedOn())
                        break
                }
                msg := "WATT window open - waiting for 0% (F6 = stop)"
                if (msg != last) {
                    Status(msg)
                    last := msg
                }
                Sleep, % RandInt(25, 45)
                continue
            }
        }
        if (LedGreenOn()) {
            ReleaseKeys()
            msg := "SUCCESS - waiting for next WATT window (F6 = stop)"
            if (msg != last) {
                Status(msg)
                last := msg
            }
            Sleep, % RandInt(150, 250)
        } else if (NavEnabled) {
            last := ""
            NavStep()
        } else {
            msg := "No WATT window - waiting (F6 = stop)"
            if (msg != last) {
                Status(msg)
                last := msg
            }
            Sleep, % RandInt(150, 250)
        }
    }
    Armed := true
    LedSeen := Now()
    Sleep, % RandInt(ResumeDelayMin, ResumeDelayMax)
    return Running
}

; Обход круга (до LockOnMin точек) и точное наведение. ЛКМ зажимается только при PressMin (5) точках.
; Возвращает "ok" / "miss" (сигнал есть, 5 точек не набрали) / "none" (сигнала нет) / "lost" / "stopped"
Seek() {
    global Running, Held, SweepStep, MinStep, PressMin, FullMin, LockOnMin, MinSignal, ScanR, CurR, RadiusJitter, RingCX, RingCY, Sc
    global SweepStepRndMin, SweepStepRndMax, GlideEnabled, GlideLagMs, RefineStart, RefineGain, RefineMaxMs, RefineIterMax, RefineShrink
    CurR := ScanR * (1 + RandF(-RadiusJitter, RadiusJitter))
    dirS := (RandF(0.0, 1.0) < 0.5) ? 1 : -1
    ; начинаем рядом с тем местом круга, где уже стоит мышь (без большого прыжка)
    MouseGetPos, mx, my
    ddx := mx - Px(RingCX)
    ddy := my - Py(RingCY)
    dd := Sqrt(ddx * ddx + ddy * ddy) / Sc
    if (dd > 30 && dd < 330)
        a := ATan2(ddy, ddx) * 57.29578 + RandF(-12.0, 12.0)
    else
        a := RandF(0.0, 360.0)
    bestS := -1
    bestA := a
    full := false
    if (GlideEnabled) {
        ; непрерывный обход, затем возврат на величину запаздывания игры
        gst := Glide(a, dirS, ga, gs, gw)
        if (gst != "found")
            return gst
        ; назад не возвращаемся (та сторона уже пройдена, там точек меньше): ждём, пока игра догонит, и читаем на месте
        bestA := ga
        Sleep, % GlideLagMs
        s := GoRead(bestA)
        if (s < 0)
            return "lost"
        bestS := s
        if (s >= PressMin && !Held)
            PressLmb()
        if (s >= FullMin)
            full := true
        if (bestS < MinSignal)
            return "miss"
    } else {
        covered := 0
        while (covered < 360) {
            if (!Running)
                return "stopped"
            s := GoRead(a)
            if (s < 0)
                return "lost"
            if (s > bestS) {
                bestS := s
                bestA := a
            }
            if (s >= LockOnMin) {
                if (s >= PressMin && !Held)
                    PressLmb()
                if (s >= FullMin)
                    full := true
                break
            }
            st := SweepStep * RandF(SweepStepRndMin, SweepStepRndMax)
            a += dirS * st
            covered += st
        }
        if (bestS < MinSignal)
            return "none"
    }

    cur := bestA
    curS := bestS
    if (!full) {
        stp := GlideEnabled ? RefineStart : SweepStep / 2
        iter := 0
        tRef := Now()
        d0 := dirS
        nDir := GlideEnabled ? 1 : 2   ; при плавном обходе пик только впереди по ходу движения: назад не ищем
        while (!full && stp >= MinStep && iter < RefineIterMax && Now() - tRef < RefineMaxMs) {
            if (!Running)
                return "stopped"
            iter++
            improved := false
            Loop, %nDir% {
                dir := (A_Index = 1) ? d0 : -d0
                s := GoRead(cur + dir * stp)
                if (s < 0)
                    return "lost"
                if (!Held && s >= PressMin)
                    PressLmb()
                if (s > curS + RefineGain) {
                    cur := cur + dir * stp
                    curS := s
                    improved := true
                    d0 := dir
                    stp := stp * RefineShrink
                    if (s >= FullMin)
                        full := true
                    break
                }
            }
            if (!improved)
                stp := stp / 2
        }
        if (!full) {
            s := GoRead(cur)
            if (s < 0)
                return "lost"
            curS := s
        }
    }
    if (curS < PressMin)
        return "miss"
    if (!Held)
        PressLmb()
    return "ok"
}

; Плавный непрерывный обход круга: мышь не останавливается, точки читаются на ходу.
; Скорость плавно "гуляет", старт с разгона, небольшой тремор. Возвращает "found" / "none" / "lost" / "stopped".
; foundA - угол, на котором набралось LockOnMin точек (подряд 2 чтения), foundW - скорость в этот момент, град/с.
Glide(a0, dirS, ByRef foundA, ByRef foundS, ByRef foundW) {
    global Running, RingCX, RingCY, CurR, Sc, GlideDps, LockOnMin, FullMin, PollMin, PollMax, LockHits
    a := a0
    rad := a * 0.0174532925
    MoveHuman(Round(Px(RingCX) + CurR * Sc * Cos(rad)), Round(Py(RingCY) + CurR * Sc * Sin(rad)))
    if (!Running)
        return "stopped"
    wt := GlideDps * RandF(0.9, 1.1)
    nsx := 0
    nsy := 0
    covered := 0.0
    hits := 0
    tStart := Now()
    tPrev := tStart
    tAlive := tStart
    Loop {
        if (!Running)
            return "stopped"
        Sleep, % RandInt(PollMin, PollMax)
        tNow := Now()
        dt := (tNow - tPrev) / 1000
        tPrev := tNow
        if (dt > 0.1)
            dt := 0.1
        wt += RandF(-1.0, 1.0) * GlideDps * 0.03
        if (wt < GlideDps * 0.75)
            wt := GlideDps * 0.75
        if (wt > GlideDps * 1.25)
            wt := GlideDps * 1.25
        rp := (tNow - tStart) / 200
        if (rp > 1)
            rp := 1
        sp := wt * rp * rp * (3 - 2 * rp)
        da := sp * dt
        a += dirS * da
        covered += da
        rad := a * 0.0174532925
        nsx := (nsx + RandF(-0.5, 0.5)) * 0.93
        nsy := (nsy + RandF(-0.5, 0.5)) * 0.93
        MouseMove, % Round(Px(RingCX) + CurR * Sc * Cos(rad) + nsx * Sc), % Round(Py(RingCY) + CurR * Sc * Sin(rad) + nsy * Sc), 0
        if (tNow - tAlive > 120) {
            tAlive := tNow
            if (!WindowAlive())
                return "lost"
        }
        info := ""
        s := ReadDots(info)
        if (s >= LockOnMin) {
            hits++
            if (hits >= LockHits || s >= FullMin) {
                foundA := a
                foundS := s
                foundW := sp
                return "found"
            }
        } else {
            hits := 0
        }
        if (covered >= 360)
            return "none"
    }
}

; Зажать ЛКМ (с короткой "реакцией")
PressLmb() {
    global Running, Held, PressDelayMin, PressDelayMax, PressMin
    Sleep, % RandInt(PressDelayMin, PressDelayMax)
    if (!Running)
        return
    ; перед нажатием заново проверяем, что 5 точек всё ещё горят (на 4 и на одиночной вспышке не жмём)
    info := ""
    if (ReadDots(info) < PressMin)
        return
    Sleep, 8
    if (ReadDots(info) < PressMin)
        return
    Click, Down
    Held := true
}

; Перейти в точку круга под углом a (градусы), выдержать паузу, прочитать точки.
; Возвращает счёт (число горящих точек + доля яркости), -1 если окно закрыто.
GoRead(a) {
    global RingCX, RingCY, CurR, Sc, DwellMin, DwellMax, HesitateChance, HesitateMin, HesitateMax
    rad := a * 0.0174532925
    x := Px(RingCX) + CurR * Sc * Cos(rad)
    y := Py(RingCY) + CurR * Sc * Sin(rad)
    MoveHuman(Round(x), Round(y))
    Sleep, % RandInt(DwellMin, DwellMax)
    if (RandF(0.0, 1.0) < HesitateChance)
        Sleep, % RandInt(HesitateMin, HesitateMax)
    if (!WindowAlive())
        return -1
    info := ""
    return ReadDots(info)
}

; Держать ЛКМ, пока точек достаточно. "dropped" / "lost" / "stopped"
Hold() {
    global Running, Held, KeepMin, HoldBadMs, HoldPollMin, HoldPollMax
    if (!Held)
        PressLmb()
    badSince := 0
    Loop {
        if (!Running) {
            ReleaseLmb()
            return "stopped"
        }
        Sleep, % RandInt(HoldPollMin, HoldPollMax)
        if (!WindowAlive()) {
            ReleaseLmb()
            return "lost"
        }
        info := ""
        s := ReadDots(info)
        if (!Held && s >= PressMin)
            PressLmb()
        if (s < KeepMin) {
            if (!badSince)
                badSince := Now()
            else if (Now() - badSince > HoldBadMs) {
                ReleaseLmb()
                return "dropped"
            }
        } else {
            badSince := 0
        }
    }
}

ReleaseLmb() {
    global Held
    if (Held) {
        Click, Up
        Held := false
    }
}

; Человекоподобное перемещение: иногда небольшой перелёт и возврат
MoveHuman(tx, ty) {
    global Sc, OvershootChance, Running
    MouseGetPos, x0, y0
    dist := Sqrt((tx - x0) ** 2 + (ty - y0) ** 2) / Sc
    if (dist < 1.5) {
        MouseMove, %tx%, %ty%, 0
        return
    }
    if (dist > 60 && RandF(0.0, 1.0) < OvershootChance) {
        ux := (tx - x0) / (dist * Sc)
        uy := (ty - y0) / (dist * Sc)
        ov := RandF(3.0, 9.0) * Sc
        MoveSmooth(Round(tx + ux * ov), Round(ty + uy * ov), 0.85)
        if (!Running)
            return
        Sleep, % RandInt(20, 60)
        MoveSmooth(tx, ty, 1.0)
    } else {
        MoveSmooth(tx, ty, 1.0)
    }
}

; Один отрезок: дуга (кривая Безье), скорость "мин-рывок" с разной скоростью разгона/торможения,
; время зависит от длины пути, лёгкий тремор руки. fac - множитель времени.
MoveSmooth(tx, ty, fac) {
    global Running, Sc, MoveBaseMs, MoveMsPerPx
    MouseGetPos, x0, y0
    dx := tx - x0
    dy := ty - y0
    dist := Sqrt(dx * dx + dy * dy)
    if (dist < 1) {
        MouseMove, %tx%, %ty%, 0
        return
    }
    dur := (MoveBaseMs + MoveMsPerPx * dist / Sc) * RandF(0.85, 1.2) * fac
    pxn := -dy / dist
    pyn := dx / dist
    bend := dist * RandF(0.04, 0.12) * ((RandF(0.0, 1.0) < 0.5) ? -1 : 1)
    b2 := bend * RandF(0.4, 1.0)
    c1x := x0 + dx * 0.30 + pxn * bend
    c1y := y0 + dy * 0.30 + pyn * bend
    c2x := x0 + dx * 0.70 + pxn * b2
    c2y := y0 + dy * 0.70 + pyn * b2
    skew := RandF(0.9, 1.15)
    nsx := 0
    nsy := 0
    t0 := Now()
    Loop {
        if (!Running)
            return
        k := (Now() - t0) / dur
        if (k >= 1)
            break
        kk := k ** skew
        s := kk * kk * kk * (kk * (6 * kk - 15) + 10)
        u := 1 - s
        bx := u * u * u * x0 + 3 * u * u * s * c1x + 3 * u * s * s * c2x + s * s * s * tx
        by := u * u * u * y0 + 3 * u * u * s * c1y + 3 * u * s * s * c2y + s * s * s * ty
        nsx := (nsx + RandF(-0.5, 0.5)) * 0.93
        nsy := (nsy + RandF(-0.5, 0.5)) * 0.93
        env := Sin(k * 3.14159) * Sc
        MouseMove, % Round(bx + nsx * env), % Round(by + nsy * env), 0
        Sleep, % RandInt(4, 8)
    }
    MouseMove, %tx%, %ty%, 0
}

ATan2(y, x) {
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

; =====================================================================
; ХОДЬБА К ЖЁЛТОЙ МОЛНИИ ПО МИНИКАРТЕ
; Карта вращается вместе с камерой: "вверх" на карте = W, "влево" = A, "вниз" = S, "вправо" = D.
; Белая стрелка стоит на месте (PlayerX/PlayerY), молния сдвигается относительно неё.
; =====================================================================
Mx(bx) {
    global Sc
    return bx * Sc
}

My(by) {
    global Sc
    return A_ScreenHeight - (1080 - by) * Sc
}

; Ищет молнию-цель: жёлтое пятно нужного размера (треугольник-значок и значки у края не подходят по размеру).
; Если пятен несколько - берёт ближайшее к игроку. bx,by - экранные координаты центра.
FindBolt(ByRef bx, ByRef by, ByRef info) {
    global MapX0, MapY0, MapX1, MapY1, Sc, BoltMinPx, BoltMinW, BoltMinH, PlayerX, PlayerY
    bx := 0
    by := 0
    info := ""
    gx := Round(Mx(MapX0))
    gy := Round(My(MapY0))
    gw := Round((MapX1 - MapX0) * Sc)
    gh := Round((MapY1 - MapY0) * Sc)
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return false
    cl := []
    y := 0
    while (y < gh) {
        x := 0
        while (x < gw) {
            v := NumGet(pBits + 0, (y * gw + x) * 4, "UInt")
            if (((v >> 16) & 255) > 200) {
                g := (v >> 8) & 255
                b := v & 255
                if (g > 150 && b < 90) {
                    hit := false
                    for i, c in cl {
                        if (x >= c[1] - 6 && x <= c[3] + 6 && y >= c[2] - 6 && y <= c[4] + 6) {
                            if (x < c[1])
                                c[1] := x
                            if (y < c[2])
                                c[2] := y
                            if (x > c[3])
                                c[3] := x
                            if (y > c[4])
                                c[4] := y
                            c[5] := c[5] + 1
                            hit := true
                            break
                        }
                    }
                    if (!hit)
                        cl.Push([x, y, x, y, 1])
                }
            }
            x += 2
        }
        y += 2
    }
    pxs := Mx(PlayerX)
    pys := My(PlayerY)
    bestD := 1000000000
    found := false
    for i, c in cl {
        if (c[5] < 3)
            continue
        x0 := Max(0, c[1] - 3)
        x1 := Min(gw - 1, c[3] + 3)
        y0 := Max(0, c[2] - 3)
        y1 := Min(gh - 1, c[4] + 3)
        n := 0
        minx := 100000
        maxx := -1
        miny := 100000
        maxy := -1
        yy := y0
        while (yy <= y1) {
            xx := x0
            while (xx <= x1) {
                v := NumGet(pBits + 0, (yy * gw + xx) * 4, "UInt")
                if (((v >> 16) & 255) > 200 && ((v >> 8) & 255) > 150 && (v & 255) < 90) {
                    n++
                    if (xx < minx)
                        minx := xx
                    if (xx > maxx)
                        maxx := xx
                    if (yy < miny)
                        miny := yy
                    if (yy > maxy)
                        maxy := yy
                }
                xx++
            }
            yy++
        }
        w := maxx - minx + 1
        h := maxy - miny + 1
        cx := gx + (minx + maxx) / 2 + 0.5
        cy := gy + (miny + maxy) / 2 + 0.5
        ok := (n >= BoltMinPx * Sc * Sc && w >= BoltMinW * Sc && h >= BoltMinH * Sc)
        info .= "[" . Round(cx) . "," . Round(cy) . " n=" . n . " " . w . "x" . h . (ok ? " BOLT" : " skip") . "] "
        if (ok) {
            d := (cx - pxs) ** 2 + (cy - pys) ** 2
            if (d < bestD) {
                bestD := d
                bx := cx
                by := cy
                found := true
            }
        }
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return found
}

NavStatus(txt) {
    global NavLastStatus
    t := Now()
    if (t - NavLastStatus < 300)
        return
    NavLastStatus := t
    Status(txt)
}

; Один шаг. Вызывается, пока окна WATT нет.
; 1) если на экране виден оранжевый маркер - подходим к нему камерой+W и жмём E, когда над ним загорелась подсказка E;
; 2) иначе бежим к молнии на миникарте: камерой наводим курс, W+Shift держим (без змейки), при упоре - обход.
NavStep() {
    global PlayerX, PlayerY, Sc, ArriveR, NavBest, NavProg, StuckMs, NavLastBolt, NoBoltKeepMs, KeyDown
    global NavDeadOn, NavDeadOff, NavCone, MarkBestW, NearTries
    global CamSteer, CamDpc, CamCalDone, CamCalMs, AimDeadDeg, StillDiffMax, StillMs, StillSince
    global MarkSeenT, MarkSeenW, MarkStopW, InteractKey, NavLastInteract, MarkSeenX, MarkSeenY
    global CamDpc0, PendCnt, PendAng, PendT, NearSince, NavLastDist
    global ProactiveAvoid, NearL, NearR, AheadHits, LastAheadT, LastProact, ClearMin, BoltSearch
    global DetourHoldUntil, CircLast, CircR, CamResetEveryMs, LastCamReset
    minfo := ""
    if (FindMarker(mkx, mky, mkw, minfo)) {
        NavBest := 0
        StillSince := 0
        NavMarker(mkx, mky, mkw)
        return
    }
    ; маркер только что был рядом и пропал из виду: стоим и ищем подсказку E там, где он был. Без подсказки E не жмём.
    if (MarkSeenT > 0 && Now() - MarkSeenT < 1400 && MarkSeenW >= MarkStopW * 0.6) {
        ReleaseKeys()
        if (FindEPrompt(MarkSeenX, MarkSeenY, 0, einfo2)) {
            NavStatus("NAV: E prompt visible - pressing E")
            if (InteractKey != "" && Now() - NavLastInteract > 450) {
                NavLastInteract := Now()
                Send, {%InteractKey%}
            }
        } else {
            NavStatus("NAV: marker out of view, no E prompt - waiting")
        }
        Sleep, 30
        return
    }
    MarkBestW := 0
    NearTries := 0
    ; калибровка камеры (один раз за запуск; при неудаче повтор через 12 с)
    if (CamSteer && CamDpc = 0 && (CamCalDone = 0 || Now() - CamCalMs > 12000)) {
        CamCalDone := 1
        Status("NAV: calibrating camera...")
        if (CalibCam())
            Status("NAV: camera calibrated, " . Round(CamDpc, 4) . " deg per tick")
        else
            Status("NAV: camera calibration failed (need bolt on minimap >14 px away) - using A/D mode")
        Sleep, 200
        return
    }
    ninfo := ""
    if (!FindBolt(bx, by, ninfo)) {
        ; значок спрятался под стрелкой и маркера нет: мы стоим на точке - обходим с другой стороны
        if (CamSteer && CamDpc != 0 && NavLastDist <= ArriveR * 2.5 && Now() - NavLastBolt < 6000) {
            NearHandle()
            return
        }
        ; молнии на карте нет (возможно, закрыта стрелкой, т.е. мы почти на месте): бег не прерываем сразу
        NavBest := 0
        StillSince := 0
        if (Now() - NavLastBolt > NoBoltKeepMs) {
            ReleaseKeys()
            if (BoltSearch) {
                SearchBoltTurn()
                return
            }
            NavStatus("NAV: no bolt on minimap, no marker (F9 = nav off)")
            Sleep, 120
        } else {
            NavStatus("NAV: bolt not visible - keep running")
            Sleep, 40
        }
        return
    }
    NavLastBolt := Now()
    dx := (bx - Mx(PlayerX)) / Sc
    dy := (by - My(PlayerY)) / Sc
    dist := Sqrt(dx * dx + dy * dy)
    near := (dist <= ArriveR || (Now() - CircLast < 3000 && dist <= CircR * 2))
    NavLastDist := dist
    if (CamSteer && CamDpc != 0) {
        if (near) {
            NearHandle()
            return
        }
        NearSince := 0
        ; --- режим камеры: курс на молнию = "вверх" на карте. Поворачиваем камеру, W держим.
        ang := ATan2(dx, -dy) * 57.29578
        absA := Abs(ang)
        if (Now() - LastCamReset > CamResetEveryMs)
            CamReset()
        ; самонастройка: сравниваем, на сколько камера реально повернулась после прошлого поворота, и подправляем чувствительность
        if (PendT > 0 && Now() - PendT > 140) {
            if (dist > 25 && Abs(PendCnt) >= 25) {
                expd := PendCnt * CamDpc
                act := Wrap180(PendAng - ang - expd) + expd
                r := act / expd
                if (r > 0.08 && r < 12) {
                    CamDpc := CamDpc * r
                    if (CamDpc0 != 0 && Abs(CamDpc) < Abs(CamDpc0) * 0.08)
                        CamDpc := CamDpc0 * 0.08
                    if (CamDpc0 != 0 && Abs(CamDpc) > Abs(CamDpc0) * 12)
                        CamDpc := CamDpc0 * 12
                }
            }
            PendT := 0
        }
        holding := (Now() < DetourHoldUntil)
        if (!near && !holding && dist > ArriveR * 1.6 && absA > AimDeadDeg)
            AimTurn(ang, 1)
        w := (near || holding || absA < 100) ? 1 : 0
        SetKeys(w, 0, 0, 0)
        NavStatus("NAV: " . (near ? "at point, looking for marker" : "running") . "  course " . Round(ang) . " deg  dist " . Round(dist))
        ; заранее: если пол вплотную по обе стороны от персонажа обрывается (поперёк пути стена/трансформатор) - обходим, не дожидаясь упора
        if (ProactiveAvoid && w && !holding && absA < 40 && Now() - LastAheadT > 250) {
            LastAheadT := Now()
            ClearScan(psl, psr, pci)
            if (NearL < ClearMin && NearR < ClearMin)
                AheadHits++
            else
                AheadHits := 0
            if (AheadHits >= 2 && Now() - LastProact > 4000) {
                AheadHits := 0
                LastProact := Now()
                Status("NAV: obstacle ahead (floor ends on both sides: " . Round(NearL) . "/" . Round(NearR) . ") - detour")
                Detour()
                NavBest := 0
                return
            }
        }
        if (w) {
            d := SceneDiff()
            if (d < StillDiffMax) {
                if (StillSince = 0) {
                    StillSince := Now()
                } else if (Now() - StillSince > StillMs) {
                    StillSince := 0
                    StuckEscape()
                    NavBest := 0
                    return
                }
            } else {
                StillSince := 0
            }
        } else {
            StillSince := 0
        }
        if (near || holding || !w || absA > 60) {
            NavBest := 0
        } else if (NavBest = 0 || dist < NavBest - 1.5) {
            NavBest := dist
            NavProg := Now()
        } else if (Now() - NavProg > StuckMs) {
            StuckEscape()
            NavBest := 0
            return
        }
        Sleep, 12
        return
    }
    ; --- запасной режим (камера не откалибрована): A/D с гистерезисом
    onT := near ? 2 : NavDeadOn
    offT := near ? 1 : NavDeadOff
    cone := Max(onT, Abs(dy) * NavCone)
    w := Hyst(KeyDown["w"], -dy, onT, offT)
    s := Hyst(KeyDown["s"], dy, onT * 1.5, offT)
    a := Hyst(KeyDown["a"], -dx, cone, cone / 2)
    d := Hyst(KeyDown["d"], dx, cone, cone / 2)
    if (s)
        w := 0
    if (!(w || a || s || d))
        w := 1
    SetKeys(w, a, s, d)
    NavStatus("NAV(A/D): " . (near ? "at point, looking for marker" : "running") . "  dx " . Round(dx) . "  dy " . Round(dy) . "  dist " . Round(dist))
    if (near) {
        NavBest := 0
    } else if (NavBest = 0 || dist < NavBest - 1.5) {
        NavBest := dist
        NavProg := Now()
    } else if (Now() - NavProg > StuckMs) {
        StuckEscape()
        NavBest := 0
        return
    }
    Sleep, 15
}

; Молнии нет на миникарте и маркера нет: стоим и крутим камеру шагами, после каждого шага смотрим миникарту.
; Выходим сразу, как только видна молния / маркер / открылось окно WATT (дальше работает обычная навигация).
; Если за проход ничего не нашли - пауза BoltSearchPauseMs, затем NavStep вызовет проход снова.
SearchBoltTurn() {
    global Running, NavEnabled, CamDpc, NavLastBolt
    global BoltSearchStepDeg, BoltSearchStepCnt, BoltSearchSteps, BoltSearchSettleMs, BoltSearchPauseMs
    ReleaseKeys()
    dir := (RandInt(1, 2) = 1) ? 1 : -1
    Status("NAV: no bolt on minimap - turning camera to look for it")
    Loop, %BoltSearchSteps% {
        if (!Running || !NavEnabled)
            return false
        if (CamDpc != 0)
            CamTurnDeg(dir * BoltSearchStepDeg * RandF(0.85, 1.15))
        else
            CamTurnCnt(dir * BoltSearchStepCnt * RandF(0.85, 1.15))
        Sleep, % Round(BoltSearchSettleMs * RandF(0.9, 1.2))
        if (LedOn() || LedGreenOn())
            return true
        if (FindBolt(bx, by, bi)) {
            NavLastBolt := Now()
            return true
        }
        if (FindMarker(mkx, mky, mkw, mi))
            return true
    }
    Sleep, %BoltSearchPauseMs%
    return false
}

; Подход к оранжевому маркеру: наводим камеру на него, идём W; бег переходит в шаг рядом; E жмём, когда над маркером горит подсказка E.
NavMarker(mkx, mky, mkw) {
    global Sc, CharX, MarkDeadX, MarkStopW, MarkSlowW, MarkDegPerPx, CamSteer, CamDpc, InteractKey, NavLastInteract
    global BlindE, NearTries, MarkBestW, MarkProg, MarkStuckMs, KeyDown, EFallbackMs, MarkSeenT, MarkSeenW, MarkNearSince, LastTurnT, UseSprint
    wpx := mkw / Sc
    MarkSeenT := Now()
    MarkSeenW := wpx
    MarkSeenX := mkx
    MarkSeenY := mky
    mxb := (mkx - A_ScreenWidth / 2) / Sc + 960
    aimB := 960 + (CharX - 960) * Min(1, wpx / 260)
    ex := mxb - aimB
    einfo := ""
    if (FindEPrompt(mkx, mky, mkw, einfo)) {
        ReleaseKeys()
        NavStatus("NAV: E prompt visible - pressing E")
        if (InteractKey != "" && Now() - NavLastInteract > 450) {
            NavLastInteract := Now()
            Send, {%InteractKey%}
            NearTries++
        }
        if (NearTries >= 5) {
            ; E не сработало - возможно, встали чуть далеко: шажок вперёд
            NearTries := 0
            PressKey("w", 1)
            Sleep, 180
            PressKey("w", 0)
        }
        Sleep, 20
        return
    }
    camMode := (CamSteer && CamDpc != 0)
    wantA := 0
    wantD := 0
    if (camMode) {
        if (Abs(ex) > MarkDeadX)
            AimTurn(ex * MarkDegPerPx)
    } else {
        wantA := Hyst(KeyDown["a"], -ex, MarkDeadX, MarkDeadX / 2)
        wantD := Hyst(KeyDown["d"], ex, MarkDeadX, MarkDeadX / 2)
    }
    w := 1
    close := (wpx >= MarkStopW)
    if (close) {
        ; вплотную, но подсказки E ещё нет: идём короткими толчками (чтобы не проскочить)
        w := Mod(Floor(Now() / 180), 2)
        if (MarkNearSince = 0)
            MarkNearSince := Now()
        if (BlindE && InteractKey != "" && Now() - MarkNearSince > EFallbackMs && Now() - NavLastInteract > 900) {
            NavLastInteract := Now()
            Send, {%InteractKey%}
        }
    } else {
        MarkNearSince := 0
        if (wantA || wantD || Now() - LastTurnT < 500) {
            MarkProg := Now()
        } else if (wpx > MarkBestW + 3) {
            MarkBestW := wpx
            MarkProg := Now()
        } else if (Now() - MarkProg > MarkStuckMs) {
            StuckEscape()
            MarkBestW := 0
            MarkProg := Now()
            return
        }
    }
    PressKey("w", w)
    PressKey("a", wantA)
    PressKey("d", wantD)
    PressKey("s", 0)
    PressKey("LShift", (UseSprint && w && wpx < MarkSlowW) ? 1 : 0)
    NavStatus("NAV: marker  offset " . Round(ex) . "  width " . Round(wpx) . (close ? "  -> close, waiting for E prompt" : "  -> approaching"))
    Sleep, 12
}

; Подсказка "E" над маркером: белый скруглённый квадрат ~31x31 px (1080p) с тёмной буквой; рядом белый гаечный ключ.
FindEPrompt(mkx, mky, mkw, ByRef info) {
    global Sc
    info := ""
    x0 := Max(0, Round(mkx - 280 * Sc))
    x1 := Min(Round(Px(1630)), Round(mkx + 280 * Sc))
    y0 := Max(Round(Py(130)), Round(mky - 430 * Sc))
    y1 := Min(A_ScreenHeight, Round(mky + 30 * Sc))
    gw := x1 - x0
    gh := y1 - y0
    if (gw < 40 || gh < 40)
        return false
    hbm := CaptureDIB(x0, y0, gw, gh, pBits)
    if (!hbm || !pBits)
        return false
    st := 2
    mg := 5
    cl := []
    y := 0
    while (y < gh) {
        x := 0
        while (x < gw) {
            v := NumGet(pBits + 0, (y * gw + x) * 4, "UInt")
            if (((v >> 16) & 255) >= 235 && ((v >> 8) & 255) >= 235 && (v & 255) >= 235) {
                hit := false
                for i, c in cl {
                    if (x >= c[1] - mg && x <= c[3] + mg && y >= c[2] - mg && y <= c[4] + mg) {
                        if (x < c[1])
                            c[1] := x
                        if (y < c[2])
                            c[2] := y
                        if (x > c[3])
                            c[3] := x
                        if (y > c[4])
                            c[4] := y
                        c[5] := c[5] + 1
                        hit := true
                        break
                    }
                }
                if (!hit)
                    cl.Push([x, y, x, y, 1])
            }
            x += st
        }
        y += st
    }
    found := false
    for i, c in cl {
        w := c[3] - c[1] + st
        h := c[4] - c[2] + st
        if (c[5] < 60 || w < 24 * Sc || w > 40 * Sc || h < 24 * Sc || h > 40 * Sc)
            continue
        if (c[5] * st * st < 0.65 * w * h)
            continue
        dark := 0
        yy := c[2]
        while (yy <= c[4]) {
            xx := c[1]
            while (xx <= c[3]) {
                p := NumGet(pBits + 0, (yy * gw + xx) * 4, "UInt")
                if (((p >> 16) & 255) < 120 && ((p >> 8) & 255) < 120 && (p & 255) < 120)
                    dark++
                xx += st
            }
            yy += st
        }
        ecx := x0 + (c[1] + c[3]) / 2
        info .= "[" . Round(ecx) . "," . Round(y0 + (c[2] + c[4]) / 2) . " " . w . "x" . h . " white=" . c[5] . " dark=" . dark . "] "
        if (dark >= 8 && Abs(ecx - mkx) <= 150 * Sc) {
            found := true
            break
        }
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return found
}

; ---------- Камера ----------
Wrap180(a) {
    while (a > 180)
        a -= 360
    while (a < -180)
        a += 360
    return a
}

; Относительный поворот камеры мышью на cnt тиков (+ = вправо, если не инвертировано; знак определяет калибровка)
CamTurnCnt(cnt) {
    global CamStep, CamStepMs, LastCamMoveT
    LastCamMoveT := Now()
    cnt := Round(cnt)
    if (cnt = 0)
        return
    n := Ceil(Abs(cnt) / CamStep)
    Loop, %n% {
        stp := Round(cnt * A_Index / n) - Round(cnt * (A_Index - 1) / n)
        DllCall("mouse_event", "UInt", 0x0001, "Int", stp, "Int", 0, "UInt", 0, "UPtr", 0)
        Sleep, %CamStepMs%
    }
}

CamTurnDeg(deg) {
    global CamDpc
    if (CamDpc = 0)
        return
    CamTurnCnt(deg / CamDpc)
}

; Подвернуть камеру: errDeg > 0 - цель правее курса
AimTurn(errDeg, track := 0) {
    global CamDpc, AimGain, AimMaxCnt, LastTurnT, AimCooldownMs, PendCnt, PendAng, PendT
    if (CamDpc = 0 || Now() - LastTurnT < AimCooldownMs)
        return
    cnt := errDeg / CamDpc * AimGain
    if (cnt > AimMaxCnt)
        cnt := AimMaxCnt
    else if (cnt < -AimMaxCnt)
        cnt := -AimMaxCnt
    cnt := Round(cnt)
    CamTurnCnt(cnt)
    LastTurnT := Now()
    if (track) {
        PendCnt := cnt
        PendAng := errDeg
        PendT := Now()
    }
}

; Калибровка: крутим камеру на CalTurnCnt тиков, смотрим, на сколько градусов повернулась молния на миникарте,
; и возвращаем камеру обратно. Если карта не вращается вместе с камерой - калибровка не удалась (режим A/D).
CalibCam() {
    global CamDpc, CalTurnCnt, PlayerX, PlayerY, Sc, CamCalMs
    CamCalMs := Now()
    ReleaseKeys()
    Sleep, 150
    if (!FindBolt(bx, by, ci))
        return false
    dx := (bx - Mx(PlayerX)) / Sc
    dy := (by - My(PlayerY)) / Sc
    if (Sqrt(dx * dx + dy * dy) < 14)
        return false
    a0 := ATan2(dx, -dy) * 57.29578
    CamTurnCnt(CalTurnCnt)
    Sleep, 280
    ok := FindBolt(bx, by, ci)
    CamTurnCnt(-CalTurnCnt)
    Sleep, 220
    if (!ok)
        return false
    dx := (bx - Mx(PlayerX)) / Sc
    dy := (by - My(PlayerY)) / Sc
    a1 := ATan2(dx, -dy) * 57.29578
    d := Wrap180(a0 - a1)
    if (Abs(d) < 4 || Abs(d) > 150)
        return false
    k := d / CalTurnCnt
    if (Abs(k) < 0.015 || Abs(k) > 0.8)
        return false
    CamDpc := k
    CamDpc0 := k
    return true
}

; Грубая "разница кадров" по сетке точек фона (небо/конструкции над персонажем). Мало = картинка не меняется = стоим.
SceneDiff() {
    global SigPrev, Sc
    gx := Round(Px(380))
    gy := Round(Py(150))
    gw := Round(1100 * Sc)
    gh := Round(280 * Sc)
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return 99
    cur := []
    havePrev := (SigPrev.MaxIndex() = 160)
    sum := 0
    n := 0
    sy := 0
    while (sy < 8) {
        qy := Round((sy + 0.5) * gh / 8)
        sx := 0
        while (sx < 20) {
            qx := Round((sx + 0.5) * gw / 20)
            v := NumGet(pBits + 0, (qy * gw + qx) * 4, "UInt")
            l := (((v >> 16) & 255) * 3 + ((v >> 8) & 255) * 6 + (v & 255)) // 10
            idx := sy * 20 + sx + 1
            cur[idx] := l
            if (havePrev) {
                sum += Abs(l - SigPrev[idx])
                n++
            }
            sx++
        }
        sy++
    }
    DllCall("DeleteObject", "Ptr", hbm)
    SigPrev := cur
    return n ? sum / n : 99
}

; ---------- Свободный пол: глубина по колонкам ----------
; Для колонок экрана (кроме тела персонажа) идём снизу вверх по "полу" (асфальт: тёмный, ровный, без синевы).
; Глубина колонки = сколько px пол тянется вверх до основания препятствия. sL/sR = лучшая глубина слева/справа от персонажа.
Lm(p, w, x, y) {
    c := NumGet(p + 0, (y * w + x) * 4, "UInt")
    return (((c >> 16) & 255) * 3 + ((c >> 8) & 255) * 6 + (c & 255)) // 10
}

FloorPx(p, w, h, x, y) {
    global FloorLumMax, FloorFlat
    if (x < 7 || y < 6 || x >= w - 7 || y >= h - 6)
        return false
    c := NumGet(p + 0, (y * w + x) * 4, "UInt")
    r := (c >> 16) & 255
    g := (c >> 8) & 255
    b := c & 255
    l := (r * 3 + g * 6 + b) // 10
    if (l < 18 || l > FloorLumMax || b - r > 11)
        return false
    return (Max(Abs(Lm(p, w, x, y - 5) - l), Abs(Lm(p, w, x, y + 5) - l), Abs(Lm(p, w, x - 6, y) - l), Abs(Lm(p, w, x + 6, y) - l)) <= FloorFlat)
}

ClearScan(ByRef sL, ByRef sR, ByRef info) {
    global CharX, Sc, NearL, NearR
    sL := 0
    sR := 0
    NearL := 0
    NearR := 0
    info := ""
    bx0 := 380
    by0 := 430
    bw := 1220
    bh := 500
    gx := Round(Px(bx0))
    gy := Round(Py(by0))
    gw := Round(bw * Sc)
    gh := Round(bh * Sc)
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return false
    yb := by0 + bh - 12
    x := bx0 + 30
    while (x <= bx0 + bw - 30) {
        if (Abs(x - CharX) < 135) {
            x += 60
            continue
        }
        lx := Round((x - bx0) * Sc)
        y := yb
        bad := 0
        top := yb
        while (y > by0 + 12) {
            ly := Round((y - by0) * Sc)
            if (FloorPx(pBits, gw, gh, lx, ly)) {
                bad := 0
                top := y
            } else {
                bad++
                if (bad >= 3)
                    break
            }
            y -= 5
        }
        s := yb - top
        info .= x . ":" . s . " "
        if (Abs(x - CharX) < 240) {
            if (x < CharX) {
                if (s > NearL)
                    NearL := s
            } else {
                if (s > NearR)
                    NearR := s
            }
        }
        if (x < CharX) {
            if (s > sL)
                sL := s
        } else {
            if (s > sR)
                sR := s
        }
        x += 60
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return true
}

; Мы на точке (значок под стрелкой), а маркера не видно: постоять, затем обежать точку с другой стороны.
NearHandle() {
    global NearSince, MarkScanSteps, MarkScanDeg
    if (NearSince = 0) {
        NearSince := Now()
        CamReset(1)
        Status("NAV: at point, marker not visible - turning camera to look for it")
        if (MarkerScan(MarkScanSteps, MarkScanDeg)) {
            NearSince := 0
            return
        }
    }
    ReleaseKeys()
    NavStatus("NAV: at point, marker not visible - looking, then going around")
    if (Now() - NearSince < 1300) {
        Sleep, 40
        return
    }
    NearSince := 0
    Circle()
}

; Клавиша C: камера возвращается за спину персонажа (если камера смотрит в пол). force=1 - без ограничений.
CamReset(force := 0) {
    global CamResetOn, CamResetKeyDn, CamResetKeyUp, LastCamReset, LastCamMoveT, DetourHoldUntil
    if (!CamResetOn)
        return
    if (!force) {
        if (Now() - LastCamReset < 2500 || Now() - LastCamMoveT < 1800 || Now() < DetourHoldUntil)
            return
    }
    LastCamReset := Now()
    Send, %CamResetKeyDn%
    Sleep, % RandInt(35, 70)
    Send, %CamResetKeyUp%
    Sleep, 150
}

; Маркера не видно, а мы у точки: ходим вокруг неё по миникарте.
; Камера всё время наведена на значок молнии, жмём A или D (боком) и W/S, чтобы держать радиус CircR.
; Упёрлись (картинка не меняется) - другая сторона и радиус больше. Выход: виден маркер / открылось окно WATT / время.
Circle() {
    global Running, NavEnabled, CircSide, CircR, CircRBase, CircLevel, CircLast, CircMaxMs
    global PlayerX, PlayerY, Sc, StillDiffMax, NavLastBolt, CircScanEveryMs
    if (Now() - CircLast > 15000) {
        CircLevel := 0
        CircR := CircRBase
        CircSide := (RandInt(1, 2) = 1) ? 1 : -1
    }
    t0 := Now()
    CircLast := t0
    lastScan := t0
    stillT := 0
    ReleaseKeys()
    Status("NAV: marker hidden - circling the point by minimap, " . (CircSide > 0 ? "right" : "left") . ", radius " . Round(CircR))
    while (Running && NavEnabled && Now() - t0 < CircMaxMs) {
        if (FindMarker(mkx, mky, mkw, mi))
            break
        if (LedOn() || LedGreenOn())
            break
        if (Now() - lastScan > CircScanEveryMs) {
            lastScan := Now()
            if (MarkerScan(6, 50))
                break
        }
        if (FindBolt(bx, by, bi)) {
            NavLastBolt := Now()
            dx := (bx - Mx(PlayerX)) / Sc
            dy := (by - My(PlayerY)) / Sc
            dist := Sqrt(dx * dx + dy * dy)
            ang := ATan2(dx, -dy) * 57.29578
        } else {
            dist := 0
            ang := 0
        }
        if (dist > CircR * 2.5)
            break
        if (dist >= 4 && Abs(ang) > 8)
            AimTurn(ang)
        wantW := (dist > CircR * 1.2 && Abs(ang) < 50) ? 1 : 0
        wantS := (dist < CircR * 0.7) ? 1 : 0
        wantD := (CircSide > 0) ? 1 : 0
        wantA := (CircSide > 0) ? 0 : 1
        PressKey("w", wantW)
        PressKey("s", wantS)
        PressKey("a", wantA)
        PressKey("d", wantD)
        PressKey("LShift", 0)
        if (SceneDiff() < StillDiffMax) {
            if (stillT = 0) {
                stillT := Now()
            } else if (Now() - stillT > 500) {
                stillT := 0
                ReleaseKeys()
                CircSide := -CircSide
                CircLevel++
                CircR := Min(CircRBase + 7 * CircLevel, 36)
                Status("NAV: blocked - circling the other way, radius " . Round(CircR))
                Sleep, 80
            }
        } else {
            stillT := 0
        }
        Sleep, 15
    }
    ReleaseKeys()
    CircLast := Now()
    Sleep, 40
}

; Крутим камеру шагами и ищем оранжевый маркер. true - нашли маркер (или открылось окно WATT).
MarkerScan(steps, stepDeg) {
    global Running, NavEnabled, MarkScanSettleMs
    ReleaseKeys()
    if (FindMarker(mkx, mky, mkw, mi))
        return true
    dir := (RandInt(1, 2) = 1) ? 1 : -1
    Loop, %steps% {
        if (!Running || !NavEnabled)
            return false
        CamTurnDeg(dir * stepDeg * RandF(0.9, 1.1))
        Sleep, % Round(MarkScanSettleMs * RandF(0.9, 1.2))
        if (FindMarker(mkx, mky, mkw, mi))
            return true
        if (LedOn() || LedGreenOn())
            return true
    }
    return false
}

Orbit() {
    global Running, OrbitLevel, OrbitLast, OrbitSide
    if (Now() - OrbitLast > 25000) {
        OrbitLevel := 0
        OrbitSide := (RandInt(1, 2) = 1) ? 1 : -1
    }
    OrbitLast := Now()
    OrbitLevel++
    if (OrbitLevel > 1)
        OrbitSide := -OrbitSide
    runMs := 800 + 250 * Min(OrbitLevel, 4)
    Status("NAV: going around the point, " . (OrbitSide > 0 ? "right" : "left") . " (try " . OrbitLevel . ")")
    CamTurnDeg(OrbitSide * 90)
    Sleep, 120
    SetKeys(1, 0, 0, 0)
    t0 := Now()
    lastChk := 0
    while (Running && Now() - t0 < runMs) {
        Sleep, 30
        if (Now() - lastChk > 220) {
            lastChk := Now()
            if (FindMarker(mkx, mky, mkw, mi))
                break
        }
    }
    ReleaseKeys()
    Sleep, 40
}

; Обход препятствия: смотрим, где пол уходит дальше (слева или справа), поворачиваем камеру туда и бежим;
; при повторном упоре за 9 с - другая сторона, больший угол, отход назад.
Detour() {
    global Running, DetourLevel, DetourLast, DetourSide, CamDpc, StillSince, DetourHoldUntil
    if (Now() - DetourLast > 9000)
        DetourLevel := 0
    DetourLast := Now()
    DetourLevel++
    DetourHoldUntil := Now() + 2300 + 200 * Min(DetourLevel, 3)
    StillSince := 0
    ReleaseKeys()
    ok := ClearScan(sl, sr, ci)
    side := (sr >= sl) ? 1 : -1
    if (!ok || Abs(sr - sl) < 25)
        side := (RandInt(1, 2) = 1) ? 1 : -1
    if (DetourLevel >= 2)
        side := -DetourSide
    DetourSide := side
    deg := (DetourLevel = 1) ? 50 : ((DetourLevel = 2) ? 90 : 135)
    runMs := 600 + 200 * Min(DetourLevel, 3)
    Status("NAV: obstacle - detour " . (side > 0 ? "right " : "left ") . deg . " deg (level " . DetourLevel . ")  L " . Round(sl) . " R " . Round(sr))
    if (DetourLevel >= 3) {
        PressKey("s", 1)
        Sleep, 550
        PressKey("s", 0)
    }
    CamTurnDeg(side * deg)
    Sleep, 100
    SetKeys(1, 0, 0, 0)
    t0 := Now()
    lastChk := 0
    while (Running && Now() - t0 < runMs) {
        Sleep, 30
        if (Now() - lastChk > 220) {
            lastChk := Now()
            if (FindMarker(mkx, mky, mkw, mi))
                break
        }
    }
    ReleaseKeys()
    Sleep, 40
}

; Оранжевый шеврон-маркер в мире (цвет ~224,109,45). Ищем самое большое оранжевое пятно в центральной части экрана.
; mx - экранная x центра, mw - ширина пятна (растёт по мере приближения).
FindMarker(ByRef mkx, ByRef mky, ByRef mkw, ByRef info) {
    global MarkX0, MarkY0, MarkX1, MarkY1, MarkStride, MarkMinSamples, Sc
    mkx := 0
    mky := 0
    mkw := 0
    info := ""
    gx := Round(Px(MarkX0))
    gy := Round(Py(MarkY0))
    gw := Round((MarkX1 - MarkX0) * Sc)
    gh := Round((MarkY1 - MarkY0) * Sc)
    st := Max(2, Round(MarkStride * Sc))
    exX := Round(Px(372)) - gx
    exY := Round(Py(770)) - gy
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return false
    cl := []
    y := 0
    while (y < gh) {
        x := 0
        while (x < gw) {
            v := NumGet(pBits + 0, (y * gw + x) * 4, "UInt")
            r := (v >> 16) & 255
            if (r >= 175 && r <= 250 && !(x < exX && y > exY)) {
                g := (v >> 8) & 255
                b := v & 255
                if (g >= 80 && g <= 145 && b <= 95 && r - b >= 120) {
                    hit := false
                    for i, c in cl {
                        if (x >= c[1] - 2 * st && x <= c[3] + 2 * st && y >= c[2] - 2 * st && y <= c[4] + 2 * st) {
                            if (x < c[1])
                                c[1] := x
                            if (y < c[2])
                                c[2] := y
                            if (x > c[3])
                                c[3] := x
                            if (y > c[4])
                                c[4] := y
                            c[5] := c[5] + 1
                            hit := true
                            break
                        }
                    }
                    if (!hit)
                        cl.Push([x, y, x, y, 1])
                }
            }
            x += st
        }
        y += st
    }
    DllCall("DeleteObject", "Ptr", hbm)
    best := 0
    bn := 0
    for i, c in cl {
        info .= "[" . Round(gx + (c[1] + c[3]) / 2) . "," . Round(gy + (c[2] + c[4]) / 2) . " n=" . c[5] . " w=" . (c[3] - c[1] + st) . "] "
        if (c[5] > bn) {
            bn := c[5]
            best := i
        }
    }
    if (bn < MarkMinSamples)
        return false
    c := cl[best]
    mkx := gx + (c[1] + c[3]) / 2 + st / 2
    mky := gy + (c[2] + c[4]) / 2 + st / 2
    mkw := c[3] - c[1] + st
    return true
}

; Гистерезис: если клавиша уже нажата - держим, пока значение > off; если нет - нажимаем, когда > on
Hyst(cur, v, on, off) {
    return cur ? (v > off) : (v > on)
}

; Эскалация при застревании: 1-й раз - прыжок и шаг вбок; повторно (в течение 9 с) - крутим камеру и ищем выход.
StuckEscape() {
    global CamSteer, CamDpc, JumpOn, JumpLast, JumpTries, StillDiffMax
    if (Now() - JumpLast > 9000)
        JumpTries := 0
    ; сначала пробуем прыгнуть (W остаётся зажатой): бордюр, кабель, низкая плита
    if (JumpOn && JumpTries < 2) {
        JumpTries++
        JumpLast := Now()
        SceneDiff()
        Jump()
        Sleep, 450
        if (SceneDiff() > StillDiffMax * 1.6) {
            Status("NAV: jumped - moving again")
            return
        }
    }
    if (CamSteer && CamDpc != 0)
        Detour()
    else
        StuckEscapeOld()
}

StuckEscapeOld() {
    global StuckCount, StuckLast
    if (Now() - StuckLast > 9000)
        StuckCount := 0
    StuckLast := Now()
    StuckCount++
    if (StuckCount = 1)
        Unstick()
    else
        CamEscape()
}

; Поворот камеры мышью (относительное движение, как в аим-скриптах для игр: mouse_event 0x0001)
CamTurn(dxPx) {
    n := Ceil(Abs(dxPx) / 12)
    if (n < 1)
        return
    stp := Round(dxPx / n)
    Loop, %n% {
        DllCall("mouse_event", "UInt", 0x0001, "Int", stp, "Int", 0, "UInt", 0, "UPtr", 0)
        Sleep, 8
    }
}

; Крутим камеру шагами; после каждого поворота бежим вперёд ~0.7 с и смотрим, стали ли ближе к молнии на карте.
CamEscape() {
    global Running, CamTurnPx, CamTries, Sc, PlayerX, PlayerY
    ReleaseKeys()
    Status("NAV: stuck - turning camera, looking for a way")
    d0 := -1
    if (FindBolt(bx, by, ci))
        d0 := Sqrt((bx - Mx(PlayerX)) ** 2 + (by - My(PlayerY)) ** 2) / Sc
    sgn := (RandInt(1, 2) = 1) ? 1 : -1
    Loop, %CamTries% {
        if (!Running)
            return
        CamTurn(sgn * CamTurnPx)
        Sleep, 80
        SetKeys(1, 0, 0, 0)
        Sleep, 700
        ReleaseKeys()
        Sleep, 60
        if (FindBolt(bx, by, ci)) {
            d1 := Sqrt((bx - Mx(PlayerX)) ** 2 + (by - My(PlayerY)) ** 2) / Sc
            if (d0 >= 0 && d1 < d0 - 4)
                return
            d0 := d1
        }
    }
}

; Застряли: отпустить всё, прыжок, шаг вбок вперёд-вбок
Unstick() {
    ReleaseKeys()
    Send, {Space}
    k := (RandInt(1, 2) = 1) ? "a" : "d"
    PressKey(k, 1)
    PressKey("w", 1)
    Sleep, 450
    ReleaseKeys()
}

; Нажать пробел (прыжок), скан-код - не зависит от раскладки
Jump() {
    global JumpKeyDn, JumpKeyUp
    Send, %JumpKeyDn%
    Sleep, % RandInt(40, 90)
    Send, %JumpKeyUp%
}

SetKeys(w, a, s, d) {
    global UseSprint
    PressKey("w", w)
    PressKey("a", a)
    PressKey("s", s)
    PressKey("d", d)
    PressKey("LShift", (UseSprint && (w || a || s || d)) ? 1 : 0)
}

PressKey(k, want) {
    global KeyDown, KeyTime, KeyHoldMs
    cur := KeyDown[k] ? 1 : 0
    if (want && !cur) {
        if ((k = "a" && KeyDown["d"]) || (k = "d" && KeyDown["a"]))
            return
        Send, {%k% down}
        KeyDown[k] := 1
        KeyTime[k] := Now()
    } else if (!want && cur) {
        if ((k = "a" || k = "d") && Now() - KeyTime[k] < KeyHoldMs)
            return
        Send, {%k% up}
        KeyDown[k] := 0
    }
}

ReleaseKeys() {
    global KeyDown
    for k, v in KeyDown {
        if (v) {
            Send, {%k% up}
            KeyDown[k] := 0
        }
    }
}

; =====================================================================
; ЧТЕНИЕ ЭКРАНА
; =====================================================================
; Пересчёт базовых координат (1080p) в текущие: от центра экрана, масштаб по высоте
Px(bx) {
    global Sc
    return A_ScreenWidth / 2 + (bx - 960) * Sc
}

Py(by) {
    global Sc
    return A_ScreenHeight / 2 + (by - 540) * Sc
}

; Горящие точки ищутся в полосе вокруг ожидаемого места (положение ряда в игре плавает).
; Счёт = число горящих точек (отдельных оранжевых пятен) + (0..0.5) за яркость.
; info = "n=<число> <x центра>:<R-B> ..." для диагностики.
ReadDots(ByRef info) {
    global DotX0, DotStep, DotY, DotBandX, DotBandUp, DotBandDn, Sc, LitMin, LitFull
    info := ""
    gx := Round(Px(DotX0 - DotBandX))
    gy := Round(Py(DotY - DotBandUp))
    gw := Round((4 * DotStep + 2 * DotBandX) * Sc)
    gh := Round((DotBandUp + DotBandDn) * Sc)
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return 0
    minW := Max(2, Round(3 * Sc))
    nLit := 0
    sumF := 0.0
    runW := 0
    runStart := 0
    runMax := -255
    gap := 0
    found := ""
    x := 0
    while (x <= gw) {
        colMax := -255
        if (x < gw) {
            y := 0
            while (y < gh) {
                v := NumGet(pBits + 0, (y * gw + x) * 4, "UInt")
                dd := ((v >> 16) & 255) - (v & 255)
                if (dd > colMax)
                    colMax := dd
                y += 2
            }
        }
        if (colMax >= LitMin) {
            if (runW = 0)
                runStart := x
            runW++
            gap := 0
            if (colMax > runMax)
                runMax := colMax
        } else if (runW > 0) {
            gap++
            if (gap >= 2 || x >= gw) {
                if (runW >= minW && nLit < 5) {
                    nLit++
                    f := (runMax - LitMin) / (LitFull - LitMin)
                    if (f > 1)
                        f := 1
                    sumF += f
                    found .= Round(gx + runStart + runW / 2) . ":" . runMax . " "
                }
                runW := 0
                runMax := -255
                gap := 0
            }
        }
        x++
    }
    DllCall("DeleteObject", "Ptr", hbm)
    info := "n=" . nLit . " " . found
    return nLit + sumF / 10
}

; Текст "0%" в центре кольца: белый, шириной в одну цифру + "%", и нет оранжевого логотипа загрузки.
; Считает каждый 2-й пиксель (быстро), счётчики приведены к полному размеру и к масштабу 1080p.
ZeroStats(ByRef wht, ByRef org, ByRef ext) {
    global ZeroX0, ZeroY0, ZeroW, ZeroH, Sc
    wht := 0
    org := 0
    ext := 0
    gx := Round(Px(ZeroX0))
    gy := Round(Py(ZeroY0))
    gw := Round(ZeroW * Sc)
    gh := Round(ZeroH * Sc)
    hbm := CaptureDIB(gx, gy, gw, gh, pBits)
    if (!hbm || !pBits)
        return
    VarSetCapacity(colW, gw * 4, 0)
    y := 0
    while (y < gh) {
        x := 0
        while (x < gw) {
            v := NumGet(pBits + 0, (y * gw + x) * 4, "UInt")
            r := (v >> 16) & 255
            g := (v >> 8) & 255
            b := v & 255
            if (r >= 170 && g >= 170 && b >= 170) {
                wht++
                NumPut(NumGet(colW, x * 4, "UInt") + 1, colW, x * 4, "UInt")
            } else if (r >= 150 && r - b >= 100) {
                org++
            }
            x += 2
        }
        y += 2
    }
    DllCall("DeleteObject", "Ptr", hbm)
    first := -1
    last := -1
    x := 0
    while (x < gw) {
        if (NumGet(colW, x * 4, "UInt") >= 2) {
            if (first < 0)
                first := x
            last := x
        }
        x += 2
    }
    if (first >= 0)
        ext := (last - first + 2) / Sc
    wht := wht * 4 / (Sc * Sc)
    org := org * 4 / (Sc * Sc)
}

ZeroOn() {
    global ZeroWhiteMin, ZeroWhiteMax, ZeroOrangeMax, ZeroExtMin, ZeroExtMax
    ZeroStats(w, o, e)
    return (w >= ZeroWhiteMin && w <= ZeroWhiteMax && o < ZeroOrangeMax && e >= ZeroExtMin && e <= ZeroExtMax)
}

; Число "оранжевых" пикселей индикатора WATT в окне 9x9
LedCount() {
    global LedX, LedY, LedMin
    gx := Round(Px(LedX)) - 4
    gy := Round(Py(LedY)) - 4
    hbm := CaptureDIB(gx, gy, 9, 9, pBits)
    if (!hbm || !pBits)
        return 0
    n := 0
    i := 0
    while (i < 81) {
        v := NumGet(pBits + 0, i * 4, "UInt")
        r := (v >> 16) & 255
        b := v & 255
        if (r > 150 && r - b > LedMin)
            n++
        i++
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return n
}

LedOn() {
    return (LedCount() >= 8)
}

; Зелёный индикатор = экран "Успех"
LedGreenCount() {
    global LedX, LedY, LedGreenMin
    gx := Round(Px(LedX)) - 4
    gy := Round(Py(LedY)) - 4
    hbm := CaptureDIB(gx, gy, 9, 9, pBits)
    if (!hbm || !pBits)
        return 0
    n := 0
    i := 0
    while (i < 81) {
        v := NumGet(pBits + 0, i * 4, "UInt")
        r := (v >> 16) & 255
        g := (v >> 8) & 255
        if (g > 100 && g - r > LedGreenMin)
            n++
        i++
    }
    DllCall("DeleteObject", "Ptr", hbm)
    return n
}

LedGreenOn() {
    return (LedGreenCount() >= 8)
}

; Окно WATT есть, пока виден оранжевый индикатор. Зелёный ("Успех") - сразу "нет окна".
WindowAlive() {
    global LedSeen, LostMs
    if (LedOn()) {
        LedSeen := Now()
        return true
    }
    if (LedGreenOn())
        return false
    return (Now() - LedSeen <= LostMs)
}

DebugDump() {
    global PlayerX, PlayerY, DotX0, DotStep, DotY, LedX, LedY, Sc, RingCX, RingCY, ScanR, ZeroWhiteMin, ZeroWhiteMax, ZeroOrangeMax, ZeroExtMin, ZeroExtMax
    global CamSteer, CamDpc, ClearMin, NearL, NearR
    Status("Debug...")
    info := ""
    s := ReadDots(info)
    txt := "screen " . A_ScreenWidth . "x" . A_ScreenHeight . "  dpi " . A_ScreenDPI . "  Sc " . Round(Sc, 4) . "`n"
    txt .= "ring centre " . Round(Px(RingCX)) . "," . Round(Py(RingCY)) . "  scan radius " . Round(ScanR * Sc) . "`n"
    txt .= "expected dot1 at " . Round(Px(DotX0)) . "," . Round(Py(DotY)) . "  expected dot5 at " . Round(Px(DotX0 + 4 * DotStep)) . "," . Round(Py(DotY)) . "`n"
    txt .= "dots (centre x:R-B): " . info . " score " . Round(s, 2) . "`n"
    txt .= "led at " . Round(Px(LedX)) . "," . Round(Py(LedY)) . " orange pixels " . LedCount() . " (need 8+), green pixels " . LedGreenCount() . " (success screen, need 8+)`n"
    nok := FindBolt(nbx, nby, ninfo)
    if (nok)
        txt .= "minimap: bolt FOUND at " . Round(nbx) . "," . Round(nby) . "  dx " . Round((nbx - Mx(PlayerX)) / Sc) . " dy " . Round((nby - My(PlayerY)) / Sc) . " | " . ninfo . "`n"
    else
        txt .= "minimap: bolt NOT found | " . ninfo . "`n"
    mok := FindMarker(kx, ky, kw, kinfo)
    txt .= "marker: " . (mok ? "FOUND at " . Round(kx) . "," . Round(ky) . " width " . Round(kw / Sc) : "NOT found") . " | " . kinfo . "`n"
    txt .= "camera: CamSteer " . CamSteer . "  deg per tick " . Round(CamDpc, 4) . " (0 = not calibrated)`n"
    cok := ClearScan(csl, csr, cinfo)
    txt .= "near-body floor depth: left " . Round(NearL) . " right " . Round(NearR) . " (obstacle ahead if both < " . ClearMin . ")`n"
    txt .= "floor clearance (x:depth px, bigger = more open; need >" . ClearMin . "): left " . Round(csl) . " right " . Round(csr) . " | " . cinfo . "`n"
    if (mok) {
        eok := FindEPrompt(kx, ky, kw, einfo)
        txt .= "E prompt: " . (eok ? "SEEN" : "not seen") . " | " . einfo . "`n"
    }
    mx0 := Max(0, Round(Mx(26)))
    my0 := Max(0, Round(My(850)))
    mw := Min(A_ScreenWidth - mx0, Round(330 * Sc))
    mh := Min(A_ScreenHeight - my0, Round(200 * Sc))
    mhb := CaptureDIB(mx0, my0, mw, mh, mpBits)
    SaveBMP(mpBits, mw, mh, A_ScriptDir . "\electric_minimap.bmp")
    DllCall("DeleteObject", "Ptr", mhb)
    ZeroStats(zw, zo, ze)
    txt .= "zero check: white " . Round(zw) . " (need " . ZeroWhiteMin . ".." . ZeroWhiteMax . "), orange " . Round(zo) . " (need <" . ZeroOrangeMax . "), width " . Round(ze) . " (need " . ZeroExtMin . ".." . ZeroExtMax . ") -> " . (ZeroOn() ? "0% SEEN" : "no 0%") . "`n"
    FileDelete, %A_ScriptDir%\electric_debug.txt
    FileAppend, %txt%, %A_ScriptDir%\electric_debug.txt, UTF-8
    x := Max(0, Round(Px(570)))
    y := Max(0, Round(Py(150)))
    w := Min(A_ScreenWidth - x, Round(780 * Sc))
    h := Min(A_ScreenHeight - y, Round(780 * Sc))
    hbm := CaptureDIB(x, y, w, h, pBits)
    SaveBMP(pBits, w, h, A_ScriptDir . "\electric_scan.bmp")
    DllCall("DeleteObject", "Ptr", hbm)
    Status("DEBUG saved: dots " . info . "| led " . LedCount() . " green " . LedGreenCount())
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
