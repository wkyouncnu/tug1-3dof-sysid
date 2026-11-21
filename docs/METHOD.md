# 식별 방법 — 단계별 절차

> 수식과 규약의 근거: [`THEORY.md`](THEORY.md) · 수치 결과: [`RESULTS.md`](RESULTS.md)
> 실행 명령: [`../README.md`](../README.md) §4

전체 파이프라인은 10단계다. 각 단계에 담당 스크립트와 "왜 그렇게 했는가"를 함께 적는다.

```
① 실험 역공학 (Simulink)  ② T200 곡선 적합  ③ ULog 파싱  ④ 작용력 재구성
⑤ 구간 분할·데이터셋 분할  ⑥ 수치미분  ⑦ 선형 LS 초기값  ⑧ 출력오차 최적화
⑨ 모델구조 선정  ⑩ val/test 평가 + Simulink 이식
```

---

## ① 실험 역공학 — 온보드 Simulink 코드를 먼저 읽는다

**스크립트: 없음 (수동 분석). 결과는 `tug_params.m` 에 상수로 박혀 있다.**

데이터를 보기 전에 **"그 데이터가 어떻게 만들어졌는지"** 를 확정해야 한다.
`for_systemID/simulink/` 의 온보드 모델을 블록 단위로 추적해 지령 사슬을 복원했다
([`THEORY.md`](THEORY.md) §4.1).

확정한 사실:

| 항목 | 값 |
|---|---|
| RC 채널 | ch3 = surge, ch1 = yaw, ch5 = arm, ch7 = controller enable |
| 스틱 데드밴드 | surge ±0.10, yaw ±0.05 |
| 지령 이득 | `s_x < 0 ? ×56.66 : ×71.71` / `s_N < 0 ? ×33.42 : ×37.18` |
| **sway 채널** | **Constant 0 으로 하드와이어 (조종기에 스틱이 없다)** |
| 추력배분 | daisy-chain. 선수 추진기를 먼저 포화시키고 잔여를 후미에 배분 |
| 모터 데드밴드 | ±33 rad/s (⇔ `\|f\| ≤ 0.40 N`) |
| PWM 권한 | `[1200, 1800]` µs (1100–1900 이 아니다) |
| 로그의 `taux/tauy/taun` | **배분 전 지령** |
| 로그의 `motor1..3` | 지령 회전수 |
| 로그의 `spare_one/two/three` | **최종 PWM (ESC 가 실제로 받는 값)** |

**이 단계를 건너뛰면 `tauy = 0` 을 "sway 입력이 없었다"로 오해하고,
선수 추진기가 전 기동의 주 yaw 구동기였다는 사실을 놓친다.**
그러면 `tau_y` 를 0 으로 넣고 식별해 완전히 틀린 계수가 나온다.

---

## ② T200 PWM–추력 곡선 적합

**스크립트: `t200_fit.m` → `../out/t200_18p5V.mat`, `../figs/t200_fit_18p5V.png`**

입력: `data/t200/T200-Public-Performance-Data-10-20V-September-2019.xlsx` (Blue Robotics 공개 데이터)

절차:
1. 18.5 V 시트/열만 추출 (`readtable` → 전압 열 필터)
2. 추력 단위 kgf → N (`×9.80665`)
3. PWM 을 **균일격자 `1200:4:1800`** (151점) 으로 재샘플 — Simulink Lookup Table 의
   breakpoint 로 쓰려면 단조·균일이 편하다
4. 데드밴드 구간을 식별해 추력을 **정확히 0** 으로 강제
5. 정/역방향 각각 `f = k n²` 2차 모델도 함께 적합 (`k_pos`, `k_neg`) — 온보드
   역변환(`n = sign(f)√(|f|/k)`)을 재현하기 위함

출력 구조체 (★ **`-struct` 로 저장했으므로 `load()` 하면 22개 필드가 최상위에 온다**):

| 필드 | 내용 |
|---|---|
| `pwm` | 1200:4:1800, 151점 |
| `f` | 추력 [N], 범위 −29.4138 … +37.1093 |
| `n` | 회전수 [rad/s] |
| `k_pos`, `k_neg` | 2차 모델 계수 |
| `R2`, `rmse` | 0.99973, 0.266 N |

⚠️ `f_max`/`f_min` **필드**(+36.443 / −28.590 N)는 2차 모델의 극값이다.
룩업에는 **격자 벡터 `f` 의 실제 범위**를 써야 한다.

---

## ③ ULog 파싱 → 상태 복원

**스크립트: `ulog2run.m` (단일 파일) · `tug_build_dataset.m` (일괄)**

### 쓰는 uORB 토픽

| 토픽 | 쓰는 필드 | 용도 |
|---|---|---|
| `vehicle_local_position` | `vx, vy, vz` | **월드 NED 속도** → 바디 변환 |
| `vehicle_attitude` | `q` | DCM, `psi` |
| `vehicle_angular_velocity` | `xyz(3)` | `r` (이미 바디 FRD) |
| `vehicle_gps_position` | `lat, lon` | **`x, y`** |
| `actuator_outputs` | `output(1..3)` 상당 | PWM (로그에서 `spare_*` 로 매핑) |
| `debug_vect` / 커스텀 | `taux, tauy, taun, motor1..3` | 지령 (검증용) |
| `battery_status` | `current_average_a` | 전압 확인 시도 |

### ★ `x, y` 는 GPS 에서 만든다

`vehicle_local_position.x/y` 를 쓰지 않는다. 그 값은 EKF 의 로컬 원점이 재설정될 때
점프하며, 로그 간 원점이 다르다. 대신

```matlab
[xn, ye, ~] = lla2ned([lat, lon, alt], [lat0, lon0, alt0], 'flat');
```

로 첫 유효 GPS 샘플을 원점으로 삼아 일관된 NED 위치를 만든다.

### 시간축 정렬

토픽마다 발행주기가 다르다. **`merge_asof` 상당의 최근접 정렬**을 쓴다:
`Ts = 0.02 s` (50 Hz) 균일격자를 만들고 각 토픽을 `interp1(..., 'linear')` 로 올린다.
PWM 도 **선형보간**한다 (최근접으로 하면 데드밴드 경계에서 계단이 생겨 작용력이 튄다).

### 전압 확인 — 실패

`battery_status` 의 `voltage_v`, `voltage_filtered_v`, `current_a`, `remaining`,
`connected` 가 **전부 정확히 0** 이다. `current_average_a` 만 13.47–14.94 A 로 유효하다.
**⇒ 18.5 V 는 로그로 검증할 수 없다. 사용자 진술에 의존한다.** 한계로 기록한다.

### 유효성 판정

`R.ok`, `R.msg`, `R.chk` 로 각 로그의 상태를 남긴다. 토픽 누락·GPS 미고정·구간 과소는
`ok = false` 로 걸러진다. 144개 중 143개가 유효했다.

---

## ④ 작용력 재구성

**스크립트: `tau_from_log.m`**

```matlab
pwm = min(max(pwm_log, P.PWM_LO), P.PWM_HI);         % [1200, 1800]
f   = interp1(T200.pwm, T200.f, pwm, 'linear');
db  = pwm >= min(T200.pwm(T200.n==0)) & ...
      pwm <= max(T200.pwm(T200.n==0));
f(db) = 0;                                            % 데드밴드 명시적 0
tau = f * P.T.';                                      % tau = T f
```

**PWM 을 1차 기준으로 삼은 이유.** `motor1..3`(회전수)에서 역산한 PWM 과 로그 PWM 이
최대 **73 µs** 어긋났다. 온보드 룩업표와 `t200_fit` 의 역변환이 완전히 같지 않기 때문이다.
ESC 가 실제로 받는 신호는 PWM 이므로 PWM 이 진실이다.

재구성 결과: `tau_y ∈ [−29.4, +37.1] N`. 로그의 `tauy ≡ 0` 과 전혀 다르다.

**공선성 진단 (이 단계에서 반드시 본다):**

| 양 | 값 |
|---|---|
| `corr(tau_y, tau_N)` | **0.959** |
| `corr(r, tau_y)` | 0.864 |
| 선수 추진기 포화 근접 비율 | 0.331 |

선수 추진기가 포화하지 않는 동안 `f₃ = N/l₃` 가 **정확히** 성립하므로
`tau_y` 와 `tau_N` 은 구조적으로 거의 같은 신호다. 포화 구간(33 %)만이
두 신호를 분리하는 유일한 정보원이다.
**⇒ sway 계수와 yaw 계수를 깨끗하게 분리할 수 없다. 순수 crabbing 기동이 필요하다.**

---

## ⑤ 구간 분할과 데이터셋 분할

**스크립트: `tug_segs.m` (활성구간) · `tug_build_dataset.m` (분할)**

### 활성구간 추출

`R.act` = (arm == on) ∧ (controller enable == on) ∧ (추력 지령 비영). 연속 구간 중
**3.0 s 이상**(`opt.min_act_s = 3.0`)만 쓴다. 짧은 구간은 과도만 있고 정보가 없다.

### 분할 규칙 — **파일 단위, 기동을 자르지 않는다**

```
각 기동 종류별로:
  지속시간 내림차순 정렬
  idx mod 5 == 0  →  test
  idx mod 5 == 1  →  val
  나머지          →  train
```

**원칙 3가지:**
1. **분할 단위는 파일(= 한 기동)이다.** 같은 기동의 앞뒤를 잘라 train/test 로 나누면
   시계열 상관 때문에 평가가 낙관적으로 오염된다.
2. **기동 종류별 층화.** 10개 종류(backward, doublet, forward_accdec, forward_full,
   reposition, spin_ccw, spin_cw, turn_ccw, turn_cw, zigzag)가 train/val/test 에
   모두 들어간다.
3. **각 종류의 가장 긴(= 진폭이 큰) 기동이 test 로 간다.** 내림차순 정렬 후
   `mod 5 == 0` 이 첫 원소를 잡기 때문이다. **학습보다 어려운 조건에서 평가한다.**

결과: 유효 143개 → train 81 / val 31 / test 31.

---

## ⑥ 수치미분

**스크립트: `sg_diff.m`**

`u̇, v̇, ṙ` 이 필요하다 (⑦ 선형 LS 용). **Savitzky–Golay 평활 후 해석적 미분**을 쓴다:

```matlab
[b, g] = sgolay(order, frame);     % order = 2 or 3, frame = 홀수
dx = conv(x, factorial(1)/(-Ts)^1 * g(:,2), 'same');
```

중앙차분이 아니라 SG 를 쓰는 이유: GPS/EKF 속도에 고주파 잡음이 있어 중앙차분이
잡음을 증폭한다. SG 는 평활과 미분을 한 번에 하며 **위상지연이 없다**(중앙 윈도우).

창 경계는 버린다(`frame` 의 절반씩).

**단, 최종 식별은 ⑧ 출력오차이므로 수치미분에 의존하지 않는다.**
⑦의 초기값 생성에만 쓴다. 이것이 수치미분 잡음의 영향을 제한하는 설계다.

---

## ⑦ 선형 최소자승 초기값

**스크립트: `tug_fit.m` · `tug_fit_int.m` · `tug_design.m` · `tug_design_int.m`**

운동방정식은 파라미터에 **선형**이다(`m11` 고정 시). 세 방정식을 적층해
하나의 `A theta = b` 로 만든다:

```
eq1:  m11 du − m22 (v r) + Xu u + Xuu |u|u + Xvv |v|v + Xrr |r|r + X0           = tau_x
eq2:  m22 dv + m23 dr + m11 (u r) + Yv v + Yvv |v|v + Yr r + Yrr |r|r
                                            + Yvr |v|r + Y0                     = tau_y
eq3:  m23 dv + m33 dr + (m22−m11)(u v) + Nr r + Nrr |r|r + Nv v + Nvv |v|v
                                            + Nuv (u v) + Nvr |v|r + Nur (u r) + N0 = tau_N
```

**적층(stacking)이 핵심이다.** `m11` 과 `m22` 가 세 방정식에 동시에 나타나므로
방정식을 따로 풀면 안 된다. 적층하면 두 값이 교차제약을 받아
전역 추력 스케일 축퇴가 부분적으로 깨진다([`THEORY.md`](THEORY.md) §5.3).

채널별 가중은 잔차 표준편차로 정규화한다. `tug_fit_int.m` 은 미분 대신 적분형
(속도 자체를 맞추는) 변형으로, 수치미분을 피하는 교차검증용이다.

**다중공선성 진단.** 각 열의 VIF 를 본다.
⚠️ `X0/Y0/N0` 의 VIF 가 1.65e12 로 나오는 것은 `corrcoef` 가 평균을 빼면서
세 상수열이 선형종속이 되는 **보고 아티팩트**다. `theta` 자체는 영향받지 않는다.

---

## ⑧ 출력오차(output-error) 최적화 — ★ 결정적 단계

**스크립트: `tug_fit_oe.m` · `tug_sim.m` · `tug_sim_batch.m` · `tug_windows.m` · `run_oe.m`**

### 왜 선형 LS 로 끝내지 않는가

선형 LS 는 **1-step 잔차**를 최소화한다. 그러나 우리의 수용 기준은
**완전재귀 롤아웃 궤적**이다. 두 목적함수는 서로 다른 최적점을 준다 —
1-step 이 더 좋은 파라미터가 롤아웃에서 더 나쁠 수 있다. 실제로 그랬다.

따라서 ⑦의 해를 **초기값으로만** 쓰고 롤아웃 목적함수로 다시 푼다.

### 목적함수

```matlab
for each window w:
    x0 = [u_m(a), v_m(a), r_m(a), 0, 0, 0];     % 초기상태만 실측
    Y  = tug_sim(Th, tau(a:b,:), Ts, x0, la);    % RK4, 완전재귀
    Z  = [u_m, v_m, r_m, x_rot, y_rot, psi_rot]; % ★ 바디 프레임 회전 적용
    res = [res; (Y − Z) ./ sd];                  % 채널별 표준편차 정규화
end
```

`lsqnonlin` (trust-region-reflective) 로 푼다. 창 길이는 `tug_windows.m` 이
활성구간을 겹치지 않게 잘라 만든다.

### ★ 바디 프레임 회전 — 가장 틀리기 쉬운 지점

롤아웃을 `psi₀ = 0` 으로 시작하면 출력 `x, y` 가 **창 시작시점 바디 프레임 변위**다.
로그의 `x, y` 는 전역 NED 다. 비교 전에 실측을 회전시킨다:

```matlab
p0 = R.psi(a);
dX = R.x(a:b) - R.x(a);   dY = R.y(a:b) - R.y(a);
xm =  cos(p0)*dX + sin(p0)*dY;
ym = -sin(p0)*dX + cos(p0)*dY;
psim = R.psi(a:b) - p0;
```

**이 회전을 빼먹으면 5초 창 위치 RMSE 가 0.14 m → 4.06 m 로 뛴다.**
모델이 틀린 것처럼 보이지만 좌표계 불일치일 뿐이다. 이 버그를 한 번 겪었다.

### RK4 세부

```matlab
d1 = f(x,          tau(t1));
d2 = f(x + h/2*d1, tau(tm));     tm = 0.5*(t1+t2)  ← tau 선형보간
d3 = f(x + h/2*d2, tau(tm));
d4 = f(x + h*d3,   tau(t2));
x_next = x + h/6*(d1 + 2*d2 + 2*d3 + d4);
```

`tm` 에서 `tau` 를 **선형보간**한다. 이것이 Simulink `From Workspace` 의
`Interpolate = on` 과 등가인 조건이다(⑩).

---

## ⑨ 모델구조 선정

**스크립트: `run_oe.m` (후보 일괄 비교) · `run_cand.m` (개별) · `tug_theta.m` (θ 변환)**

여러 항 집합을 ⑧로 각각 풀어 val 롤아웃 성능으로 비교했다.

| 검증한 가설 | 결과 |
|---|---|
| `m23` 부호 / `Nur` 유무 | **D(음수 `m23`, `Nur` 활성) 과 F3(양수 `m23`, `Nur`=0) 이 동등** |
| 선수 추진기 유효추력이 속도에 따라 감소 (`Ey1..3`) | **기각** — 개선 없음 |
| 선수 추진기 유효 모멘트팔 변동 (`dla`) | **기각** |
| 후미 추진기 속도의존 효율 (`Ex1..2`) | **기각** |

**기각의 함의가 크다.** 속도의존 추력 모델이 전부 기각되었으므로
`e1 = tau_x`, `e2 = tau_y`, `e3 = tau_N` 이 정확히 성립하고,
**`l₃` 는 운동방정식에 나타나지 않는다 — 추력배분 전단에만 쓰인다.**
이것이 Simulink 모델 구조를 단순하게 만들어 준다.

**D 와 F3 을 모두 유지한다.** 구조가 다른데 성능이 거의 같다는 사실
(ATE 2.450 vs 2.513 m)은 식별성 한계의 직접적 증거다. 기본값은 **F3**(더 단순).

`tug1_model.m` 이 두 파라미터 벡터를 `ORD` 순서로 내보낸다.
`tug_theta.m` 은 CoG 오프셋 확장형(`mxg`)을 쓸 때 `Th.m23 = Th.m23 + Th.mxg` 로 접는다.

---

## ⑩ 평가와 Simulink 이식

### 평가

**스크립트: `tug_eval.m` · `run_final.m` → `../out/tug1_final.mat`, `../figs/tug1_test_*.png`**

지표: 채널별 RMSE, ATE, 최종오차, ATE/주행거리, `ζ`, 지평 스윕.
정의는 [`THEORY.md`](THEORY.md) §6, 수치는 [`RESULTS.md`](RESULTS.md).

⚠️ `tug_eval` 의 `horiz_s = 1` 행은 **버려라.** 창 범위 필터가 ≥ 50 샘플을
요구하는데 1초 창은 49 샘플이라 전부 0 이 나온다.

### Simulink 모델 생성

| 스크립트 | 산출물 | 입력 |
|---|---|---|
| `build_tug1_slx.m` | `../out/tug1_3dof.slx` | `tau` (3×1) |
| `build_tug1_slx(mdl, true)` | `../out/tug1_3dof_alloc.slx` | 개별 추력 `f` (3×1) |
| **`build_tug1_pwm_slx.m`** | **`../out/tug1_3dof_pwm.slx`** | **PWM (3×1)** |

공통 구조:

```
[From Workspace] → ... → [Subsystem Tug1_3DOF] → [To Workspace YSIM]
                              ├ Inport  tau (3)
                              ├ Constant p = TUG1_P (23)
                              ├ MATLAB Function dyn  ← tug1_dyn.m 전문
                              └ Integrator x, IC = TUG1_X0 (6)
```

PWM 판은 전단만 다르다:

```
[From Workspace PWM_TS] → [Saturation 1200..1800]
   → [1-D Lookup  T200_PWM→T200_F] → [Gain T (Matrix K*u)] → [Tug1_3DOF]
```

동역학 서브시스템은 `build_tug1_slx` 를 먼저 호출해 만들고 선만 갈아끼우므로
**두 모델의 동역학이 바이트 단위로 같다.**

### 구현 시 걸린 것들 (재현하려면 알아야 한다)

| 함정 | 대응 |
|---|---|
| `add_block('built-in/Subsystem')` 는 **빈** 서브시스템을 만든다 (In1/Out1 없음) | Inport/Outport 를 명시적으로 추가 |
| MATLAB Function 코드를 프로그램으로 넣기 | `ch = sfroot.find('-isa','Stateflow.EMChart','Path',p); ch.Script = code;` |
| `To Workspace(Array)` 는 6×1 을 `[6 1 N]` 로 쌓는다 | `permute(squeeze(Y),[2 1])` |
| 1-D Lookup 에 3×1 벡터 입력 | **원소별로 적용된다. Demux/Mux 불필요** |
| Stateflow XML 의 한글 주석이 깨진다 | `tug1_dyn.m` 은 영문/수식 위주로 유지 |

### 등가성 검증

**스크립트: `check_slx.m` → `../out/tug1_slxchk.mat`**

같은 `tau` 를 넣어 `tug_sim`(MATLAB) 과 Simulink 를 비교한다.
일치 조건: **fixed-step `ode4`, `h = Ts = 0.02`, `From Workspace` 보간 on (ZOH 금지)**.

결과: 최대 편차 `2.1e-14 m` — **기계 정밀도.**

### 최종 검증 — PWM 을 넣어 밸리데이션 로그와 비교

**스크립트: `run_slx_val.m` → `../out/tug1_slxval.mat`, `../figs/tug1_val_slx_*.png`**

**식별에 쓰지 않은 val 31개 로그**의 PWM 을 그대로 Simulink 에 넣고 궤적을 비교한다.
섹션 구성:

| § | 내용 |
|---|---|
| 0 | val 로그 목록 (31개, 종류별 개수, 구간길이, 데드밴드 점유율) |
| 1 | 모델(D/F3) × 런별 롤아웃. `TUG1_X0`, `PWM_TS` 설정 후 `sim()` |
| 2 | 런별 지표 표 |
| 3 | 기동 종류별 집계 |
| 4 | XY 궤적 비교 그림 (10패널) |
| 5 | 6채널 × 3기동 시계열 |
| 6 | 원로그 그림 — PWM / 재구성 `tau` / 로그 `tau` 지령 (`tauy ≡ 0` 표시) |
| 7 | **PWM 입력판 vs `tau` 입력판 편차** — 전 구간 최대 3.3 cm |
| 8 | **지평 스윕** — `H ∈ {2, 5, 10} s` 마다 재초기화한 창 집계 |

§8 이 중요하다. §1–7 은 "한 번 초기화하고 끝까지" 가는 최악 조건이다.
강화학습 환경은 에피소드마다 초기화되고 제어기가 루프를 닫으므로
짧은 지평 성능이 실제로 중요하다. 같은 모델로 둘 다 보고한다.

---

## 재현 체크리스트

```
□ cwd = tug_sysid/src   (모든 스크립트가 ..\out, ..\figs, ..\data 상대경로를 쓴다)
□ t200_fit                                  → out/t200_18p5V.mat
□ tug_build_dataset('..\data\logs\tug1', '..\out\tug1_runs.mat', P, T200)
                                            → out/tug1_runs.mat  (21 MB, git 제외)
□ run_oe                                    → out/tug1_oe.mat
□ run_final                                 → out/tug1_final.mat + figs/tug1_test_*
□ build_tug1_slx                            → out/tug1_3dof.slx
□ check_slx            ★ 2.1e-14 확인
□ build_tug1_pwm_slx                        → out/tug1_3dof_pwm.slx
□ run_slx_val                               → out/tug1_slxval.mat + figs/tug1_val_slx_*
□ roll_check           (3-DOF 근사 타당성)   → out/tug1_rollchk.mat
```

`.m` 파일을 수정한 뒤에는 **`clear functions`** 를 먼저 실행한다.
MATLAB 이 이전 버전을 캐시한다.
