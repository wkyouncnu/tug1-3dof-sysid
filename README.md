# Tug USV 3-DOF 시스템 식별 (Tug 1)

쌍동형 무인 예인선(Tug 1)의 **3자유도 조종 동역학**을 실측 Pixhawk ULog 144개로부터 식별하고,
그 결과를 **PWM을 입력으로 받는 Simulink 운동모델**로 만들어 밸리데이션 데이터셋에서 궤적을 검증한 저장소다.

- 작성: 윤원근 (충남대학교 자율운항시스템공학과, AI Field Robotics Lab / ANSL)
- 대상: Tug 1 (Tug 2는 동일 형상·동일 추진배치이므로 동일 절차로 재식별 가능)
- 계측: 2026-11-20, Pixhawk / ULog, 50 Hz
- 자유도: **3-DOF (surge-sway-yaw) 전용.** 6-DOF 는 다루지 않는다.

---

## 1. 대상 선박

| 항목 | 값 |
|---|---|
| 선형 | 쌍동선(catamaran) |
| 길이 × 폭 × 높이 | 1.10 × 0.53 × 0.53 m |
| 질량 | 17.86 kg |
| 추진기 | Blue Robotics **T200 × 3** |
| 전압 | 18.5 V |
| 후미 추진기 | 좌현/우현, 바디 **+X** 방향, 반간격 `d = 0.300 m` |
| 선수 추진기 | **횡방향 전용**, 바디 **+Y** 방향, CoG 전방 `l₃ = 0.500 m` |
| PWM 권한 | 1200 – 1800 µs (중립 1500) |
| 비행제어기 | Pixhawk (PX4) |

**3-DOF 완전구동이다.** 추력배분 행렬이 정방·가역이므로 부족구동 USV 문헌과 달리
sway 를 원심결합(`−ur`)에 의존하지 않고 직접 여기할 수 있다.

```
      [X]       [ 1    1    0  ]   [f_port]
tau = [Y]   =   [ 0    0    1  ] · [f_stbd]  ,   det T = 2d = 0.6 ≠ 0
      [N]       [ d   −d   l₃  ]   [f_bow ]
```

---

## 2. 저장소 구성

```
tug_sysid/
├── README.md               ← 이 파일 (개요·실행방법·결과요약)
├── docs/
│   ├── THEORY.md           ← 이론 (좌표계·운동방정식·추력배분·T200·식별 정식화)
│   ├── THEORY.pdf          ← 위 문서의 PDF 판
│   ├── METHOD.md           ← 식별 방법 상세 (파이프라인 10단계)
│   ├── METHOD.pdf          ← 위 문서의 PDF 판
│   ├── RESULTS.md          ← 전체 정량 결과
│   └── RESULTS.pdf         ← 위 문서의 PDF 판
├── data/
│   ├── logs/tug1/          ← 원본 ULog 144개 (식별에 실제로 쓴 데이터 전부)
│   └── t200/               ← T200 제조사 공개 성능표 (xlsx)
├── src/                    ← MATLAB 소스 전부 (아래 §4)
├── tools/
│   └── md2html.py          ← MD → 인쇄용 HTML (PDF 재생성용, 의존성 없음)
├── out/                    ← 산출물 (.mat, .slx)
└── figs/                   ← 결과 그림
```

PDF 는 `docs/*.md` 에서 다시 만들 수 있다 (pandoc 불필요, Chrome 헤드리스만 쓴다):

```
python tools/md2html.py docs/THEORY.md THEORY.html "Tug 1 3-DOF 운동모델 이론"
chrome --headless=new --disable-gpu --no-pdf-header-footer ^
       --print-to-pdf=docs/THEORY.pdf file:///<절대경로>/THEORY.html
```

---

## 3. 요구 환경

- MATLAB **R2024b** 이상
- **UAV Toolbox** (`ulogreader` — ULog 파싱에 필수)
- **Simulink**
- Optimization Toolbox (`lsqnonlin`, `fmincon`)
- (선택) Global Optimization Toolbox

---

## 4. 실행 방법

전부 `src/` 를 현재 폴더로 두고 실행한다. 모든 스크립트가 `..\out\`, `..\figs\`,
`..\data\` 상대경로를 쓴다.

```matlab
cd src
```

### 4.1 T200 PWM-추력 곡선 피팅

```matlab
t200_fit
```

제조사 공개 성능표(`..\data\t200\T200-Public-Performance-Data-10-20V-September-2019.xlsx`)에서
**18.5 V 열**만 뽑아 `PWM → 추력[N]` 과 `PWM → 회전수[rad/s]` 를 만든다.

- 산출: `..\out\t200_18p5V.mat`, `..\figs\t200_fit_18p5V.png`
- 격자: `pwm = 1200:4:1800` (151점), 데드밴드 `[1476, 1528]` 에서 추력 = 0
- 추력 범위: **−29.41 … +37.11 N** (역추력이 약한 **비대칭**)
- 2차 모델 적합도: R² = 0.99973, RMSE = 0.266 N

### 4.2 ULog 144개 → 식별용 데이터셋

```matlab
P    = tug_params();
T200 = load('..\out\t200_18p5V.mat');
S    = tug_build_dataset('..\data\logs\tug1', '..\out\tug1_runs.mat', P, T200);
```

- 각 ULog → `R` 구조체 (상태·작용추력·PWM·기동종류·분할)
- `vehicle_local_position.vx/vy` 를 `vehicle_attitude.q` 의 DCM 으로 바디 회전 → `u, v`
- `vehicle_angular_velocity` → `r` (이미 바디 FRD)
- **위치 `x, y` 는 GPS 위경도를 `lla2ned` 로 변환한 값**을 쓴다
- 기동종류별 층화 분할: 지속시간 내림차순 정렬 후 `mod 5 == 0 → test`, `== 1 → val`, 나머지 `train`
  → 각 종류의 **가장 긴(= 진폭이 큰) 기동이 test 로** 간다
- 산출: `..\out\tug1_runs.mat` (21 MB — 용량 때문에 저장소에서 제외. 위 명령으로 재생성된다)

### 4.3 모델구조 후보 비교 → 최종 식별

```matlab
run_oe        % 구조 후보 D/F/G/H/F3/Fs 출력오차 최적화 비교
run_final     % 선정된 구조로 최종 식별 + test 분할 평가
```

- 산출: `..\out\tug1_oe.mat`, `..\out\tug1_final.mat`, `..\out\tug1_model.mat`

### 4.4 Simulink 운동모델 생성

```matlab
build_tug1_slx('tug1_3dof', false)   % 입력 = tau
build_tug1_pwm_slx('tug1_3dof_pwm')  % 입력 = PWM  ★ 최종 검증용
check_slx                            % MATLAB 롤아웃과 수치 일치 검증
```

`check_slx` 는 Simulink 모델과 MATLAB 적분기(`tug_sim`)가 같은 입력에 같은 답을 내는지 본다.
판정: **최대 편차 2.1e-14 m — 기계 정밀도 수준에서 일치.**

### 4.5 ★ 밸리데이션 데이터셋으로 PWM 입력 궤적 검증

```matlab
run_slx_val
```

**식별에 쓰지 않은 밸리데이션 로그 31개**의 PWM 을 그대로 Simulink 모델에 넣고
완전 개루프로 적분해 실측 궤적과 비교한다.

- 산출: `..\out\tug1_slxval.mat`
- 그림: `..\figs\tug1_val_slx_xy.png` (XY 궤적), `tug1_val_slx_ts.png` (6채널 시계열), `tug1_val_slx_log.png` (원본 로그)

---

## 5. 결과 요약

상세는 [`docs/RESULTS.md`](docs/RESULTS.md).

### 5.1 PWM 입력판 ↔ 식별 경로의 등가성

식별은 `tau` 를 입력으로 했고 최종 모델은 `PWM` 을 입력으로 받는다.
두 경로는 원리적으로 완전히 같을 수 없다 — 식별 경로는 RK4 중간스텝에서 `tau` 를 선형보간하고,
PWM 입력판은 `PWM` 을 보간한 뒤 비선형 룩업을 통과시킨다(데드밴드 경계에서 최대).
밸리데이션 31개 전 구간에서 그 차이를 측정한 값:

| 모델 | Δu | Δv | Δr | Δx | Δy | Δψ |
|---|---|---|---|---|---|---|
| D  | 2.5e-03 | 1.2e-03 | 4.8e-03 | **2.2e-02 m** | 1.8e-02 m | 2.5e-03 |
| F3 | 2.3e-03 | 8.2e-04 | 4.7e-03 | 1.2e-02 m | **3.3e-02 m** | 4.1e-03 |

최대 **3 cm**. 궤적오차(수십 cm ~ m)보다 두 자리 작으므로 두 경로는 사실상 같은 모델이다.

### 5.2 밸리데이션 31개 궤적 성능 (한 번만 초기화하고 끝까지 — 완전 개루프)

| 모델 | rmsU [m/s] | rmsV [m/s] | rmsR [rad/s] | ATE [m] | ATE/주행거리 | ζ |
|---|---|---|---|---|---|---|
| **D**  | 0.162 | 0.157 | 0.111 | **2.450** | **0.147** | 0.344 |
| **F3** | 0.235 | 0.150 | 0.105 | 2.513 | 0.160 | 0.362 |

구간 길이 3.4 – 51.4 s, 평균 15.8 s, 평균 주행거리 17.5 m.
`ζ = mean(rmse_uvr / std_uvr)` — 속도채널을 데이터 표준편차로 정규화한 복합지표.

### 5.3 지평별 성능 (H 초마다 초기화 — RL 환경의 실제 조건)

| H [s] | 창 수 | D.ATE [m] | F3.ATE [m] | D.ζ | F3.ζ |
|---|---|---|---|---|---|
| 2  | 229 | **0.229** | 0.270 | 0.254 | 0.292 |
| 5  | 83  | **0.794** | 0.789 | 0.340 | 0.373 |
| 10 | 37  | 1.865 | 1.942 | 0.354 | 0.381 |

**속도 RMSE 는 지평이 길어져도 거의 변하지 않고(0.16 / 0.15 / 0.12 고정) 위치오차만 자란다.**
수치 불안정이 아니라 속도오차의 시간적분, 즉 추측항법 누적이다.

### 5.4 기동 종류별 ATE [m]

| 기동 | n | D | F3 |
|---|---|---|---|
| spin_ccw | 2 | **0.299** | 0.802 |
| spin_cw | 2 | 0.469 | 0.711 |
| turn_ccw | 3 | 1.027 | 1.396 |
| reposition | 4 | 1.372 | 1.466 |
| forward_full | 5 | 1.519 | **1.370** |
| doublet | 3 | 1.985 | 2.478 |
| backward | 5 | 2.947 | 3.064 |
| forward_accdec | 2 | 3.031 | 3.961 |
| turn_cw | 2 | 3.167 | 3.140 |
| zigzag | 3 | 8.390 | **7.006** |

---

## 6. Simulink 연동 (후속 강화학습용)

`out/tug1_3dof_pwm.slx` 의 구조:

```
[From Workspace PWM_TS]  3×1 [µs]
      ↓
[Saturation 1200 … 1800]
      ↓
[1-D Lookup  T200_PWM → T200_F]     ← 18.5 V 실측 곡선 (데드밴드가 표에 내장)
      ↓
[Gain  T = [1 1 0; 0 0 1; d −d l₃]]  tau = T·f
      ↓
[Subsystem Tug1_3DOF]  →  [To Workspace YSIM]
```

- 솔버: **fixed-step `ode4`, h = 0.02 s** (MATLAB 롤아웃의 RK4 와 일치)
- `From Workspace` 의 **보간을 켜야** 한다(ZOH 금지). `tug_sim` 이 중간스텝에서 `tm = 0.5(t₁+t₂)` 를 쓰기 때문
- 서브시스템 `Tug1_3DOF` 만 복사해 그대로 RL 환경 모델로 쓸 수 있다
- 파라미터는 베이스워크스페이스 변수 `TUG1_P` (23×1), 초기상태는 `TUG1_X0` (6×1)

### 실행 전 필요한 베이스워크스페이스 변수

| 변수 | 내용 |
|---|---|
| `T200_PWM`, `T200_F` | 룩업표 (`t200_18p5V.mat` 의 `pwm`, `f`) |
| `TUG1_P` | 23×1 파라미터 (`tug1_model()` 반환) |
| `TUG1_X0` | `[u; v; r; x; y; psi]` 초기상태 |
| `PWM_TS` | `timeseries(pwm [N×3], t)` — 열 순서 = 좌현/우현/선수 |

---

## 7. 한계 — 솔직한 기술

1. **18.5 V 를 로그로 확인할 수 없다.** `battery_status` 의 `voltage_v`, `voltage_filtered_v`,
   `current_a`, `remaining` 이 전부 0 이다. `current_average_a` (13.5–14.9 A) 만 살아 있다.
   전압은 사용자 진술값을 그대로 받아들였다.
2. **선수 추진기와 yaw 모멘트가 거의 공선이다.** `corr(τ_y, τ_N) = 0.959`.
   선수 추진기가 포화하지 않는 동안 `f₃ = N/l₃` 가 정확히 성립해 `τ_y = 2 τ_N` 이 된다.
   따라서 sway 감쇠와 yaw 감쇠의 분리 식별이 구조적으로 불완전하다.
   이를 깨려면 **순수 crabbing 기동(`u ≈ 0, r ≈ 0, v ≠ 0`)** 데이터가 추가로 필요하다.
3. **유효질량이 물리적으로 과대하다.** `m22` 가 선체질량의 3–6.7배, `m33` 이 기하학적
   직육면체 추정의 5–7배로 나온다. 부가질량만으로 설명되는 크기가 아니다.
   추력 스케일 오차를 유효질량이 흡수한 것으로 보인다 — **계류추력 시험(bollard pull)** 으로
   `PWM → N` 곡선을 직접 계측하면 이 축퇴가 깨진다.
4. **일부 2차 감쇠항이 음수다.** 물리적으로 소산이어야 하는 항이 음수로 나온 것은
   곡선적합이 다른 항의 오차를 보상한 결과다. 궤적 재현은 맞지만 계수의 물리적 해석은 제한된다.
5. **roll/pitch 를 무시했다.** `corr(φ, r) = −0.9036` 으로 roll 은 yaw rate 와 거의 공선이라
   4번째 자유도를 넣어도 독립정보가 없다. pitch 는 roll 보다 크다(평균 +5.71°, 최대 22.68°).
   3-DOF 근사의 주된 오차원이다.
6. **지그재그 장시간 구간이 가장 불리하다.** 51.4 s 개루프에서 ATE 12.7 m (주행 67.6 m, 비율 0.19).
   heading 편향의 누적이다. 2–5 s 지평에서는 0.23–0.79 m.

---

## 8. 라이선스 / 출처

- `data/t200/T200-Public-Performance-Data-10-20V-September-2019.xlsx` 는
  Blue Robotics 가 공개한 제조사 성능 데이터다. 저작권은 Blue Robotics 에 있다.
- 그 외 코드·로그·문서는 ANSL(충남대 자율운항시스템공학과) 연구 산출물이다.
