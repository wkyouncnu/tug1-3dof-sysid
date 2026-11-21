function P = tug_params()
%TUG_PARAMS  예인선(tug) 실물 제원 + 온보드 제어기 상수 (전부 출처 명시)
%
%  [확정] = 사용자 제공 또는 Simulink/엑셀 원본에서 직접 읽음
%  [추정] = 계산으로 얻은 값. 식별로 갱신될 수 있음
%  [확인필요] = 아직 근거 없음
%
%  2026-11-20  작성

%% ===== 1. 선체 제원 ===============================================
P.L     = 1.10;      % [m]  전장            [확정] 사용자
P.B     = 0.53;      % [m]  폭              [확정] 사용자
P.H     = 0.53;      % [m]  높이            [확정] 사용자
P.m     = 17.86;     % [kg] 질량            [확정] 사용자
P.rho   = 1000;      % [kg/m^3] 담수 (수조/수영장)  [확정] 시험 수역
P.g     = 9.80665;

% 강체 yaw 관성 — 균일 직육면체 근사. m33 = Iz + a_zz 는 식별로 얻으므로
% 이 값은 "식별 결과가 물리적으로 가능한가" 검사용 하한으로만 쓴다.
P.Iz_box = P.m*(P.L^2 + P.B^2)/12;          % [추정] = 2.219 kg m^2
P.Iz_lo  = 0.8*P.Iz_box;                     % 타당 범위 하한
P.Iz_hi  = 1.5*P.Iz_box;                     % 쌍동선은 질량이 외측 선체에 몰려 커진다

%% ===== 2. 추진기 배치 =============================================
%  좌표계: 바디 FRD  (x 전방, y 우현, z 하방) = Fossen/SNAME = PX4 바디
%  f1 : 좌현 선미, +x 방향 추력, y = -d
%  f2 : 우현 선미, +x 방향 추력, y = +d
%  f3 : 선수 횡추진기, +y 방향 추력, x = +la
P.d  = 0.300;   % [m] 중심선 ~ 선미 추진기 반간격   [확정] chart_66 소스 (d = 0.3)
P.la = 0.500;   % [m] CG ~ 선수 추진기 전방거리     [확정] chart_66 소스 (la = 0.5)
% 교차검증: init_tug_2fixed_bow_systemID.m 의
%   N_max = d*(f3max + f2max) + la*f3max = 0.3*(35.855+28.33)+0.5*35.855 = 37.18  (일치)
%   N_min = -[0.3*(28.33+35.855)+0.5*28.33]                            = -33.42  (일치)

% 추력 배분 행렬  tau = T * f,  f = [f1(좌현); f2(우현); f3(선수)]
P.T = [ 1      1      0    ;
        0      0      1    ;
       +P.d  -P.d   +P.la ];
%  [확정] chart_66 소스 T = [1 1 0; 0 0 1; d -d la] 와 완전히 동일하다.
%  FRD 직접 검산 (N = x*Fy - y*Fx):
%    좌현 (x_p, -d), F=(f1,0) -> N = -(-d)*f1 = +d*f1     (OK)
%    우현 (x_s, +d), F=(f2,0) -> N = -(+d)*f2 = -d*f2     (OK)
%    선수 (+la,  0), F=(0,f3) -> N = +la*f3               (OK)
%  => 선미 추진기의 x 위치는 N 에 기여하지 않는다 (추력이 x 방향).
%     따라서 선미 추진기 종방향 위치를 몰라도 3-DOF 식별에 지장이 없다.
%  motor1/spare_one = 좌현, motor2/spare_two = 우현, motor3/spare_three = 선수
%  [확정] system_root BusAssignment 입력명 motor_left/right/bow_pwm

%% ===== 3. T200 추진기 (18.5 V) ====================================
%  온보드 제어기에 하드코딩된 값 (chart_47). 이것이 "컨트롤러가 믿은" 값이다.
P.k_pos_ctrl = 3.670142870302694e-04;   % [N/(rad/s)^2]  [확정] chart_47
P.k_neg_ctrl = 2.898839656197090e-04;   % [확정] chart_47
P.n_max_ctrl =  312.5528643154;         % [rad/s] = PWM 1800  [확정] chart_47
P.n_min_ctrl = -312.6052241930;         % [rad/s] = PWM 1200  [확정] chart_47
P.f3_max     = P.k_pos_ctrl*P.n_max_ctrl^2;             % +35.855 N
P.f3_min     = P.k_neg_ctrl*P.n_min_ctrl*abs(P.n_min_ctrl); % -28.330 N

%  엑셀 실측(18V/20V 보간) 피팅값은 t200_fit.m 이 out/t200_18p5V.mat 에 저장.
%  검증 결과: k_pos -0.093 %, k_neg -0.100 % 차이 -> 컨트롤러 상수가 맞다.
%  => 추력 스케일은 제조사 벤치데이터로 독립 확인됨 (계류시험 불필요)

%  ★ 남은 불확실성: 엑셀은 전진속도 0(볼라드) 추력이다. 실제는 전진비
%     J = U/(nD), D=0.076 m. U<=1.5 m/s, n>=100 rad/s 이면 J<=0.2 이지만
%     저속·고회전 구간은 J<0.07 로 영향이 작다. 전역 추력 스케일 k_T 를
%     식별 파라미터로 두고 사전범위 [0.85, 1.05] 로 제한한다.
P.D_prop = 0.076;    % [m] T200 프로펠러 직경  [확인필요] 공개 스펙 ~76 mm

%% ===== 4. 구동기 비선형 ===========================================
P.PWM_LO   = 1200;   % [확정] system_303 Saturation
P.PWM_HI   = 1800;   % [확정]
P.PWM_MID  = 1500;
P.n_gate   = 33;     % [rad/s] |n|<=33 -> 0  [확정] system_3165/3173/3850 DeadZone
%  33 rad/s <-> 추력 0.40 N. T200 자체 PWM 데드밴드(1476~1528) 와 거의 동일 구간.

%% ===== 5. RC 입력 규약 (= 실험을 어떻게 했는가) ====================
%  ★ 조타는 전부 수동 RC 다. 프로그램된 입력신호(PRBS/multisine)는 없다.
P.rc_ch_surge = 3;    % [확정] system_3008 Inport "ch3" -> tau_x
P.rc_ch_yaw   = 1;    % [확정] system_3008 Inport "ch1" -> tau_N
P.rc_ch_arm   = 5;    % [확정] system_3065 "ch5" -> PWM 출력 ON/OFF
P.rc_ch_enab  = 7;    % [확정] system_3000 "ch7" -> 제어기 ON/OFF
P.rc_db_surge = 0.10; % [확정] system_3056 DeadZone (정규화 후)
P.rc_db_yaw   = 0.05; % [확정] system_3032 DeadZone
%  ★★ sway 스틱이 존재하지 않는다. tau_y 지령 == 0 (Constant4) 상시.
P.tau_y_cmd_is_zero = true;

%  RC -> tau 매핑 (chart_87, 구간선형·비대칭)
P.tau_x_max = 71.71;  P.tau_x_min = -56.66;   % [확정] init 스크립트 주석
P.tau_y_max = 35.85;  P.tau_y_min = -28.33;
P.tau_N_max = 37.18;  P.tau_N_min = -33.42;

%% ===== 6. 샘플링 ==================================================
P.Ts = 0.02;          % [확정] init 스크립트 + tug_log_data 실측 50.0 Hz
P.fs = 1/P.Ts;

%% ===== 7. 데이지체인 제어배분 (실제 작용력 재구성의 핵심) =========
%  tau_y 지령이 항상 0 이므로 chart_47 의 if Y==0 분기가 상시 성립:
%     u3_N  = clamp(N/la, f3_min, f3_max)      <- 선수추진기를 yaw 에 우선 사용
%     N_res = N - la*u3_N
%     [f1; f2; f3] = T_mdl \ [X; 0; N_res]  + [0;0;u3_N]
%  => 실제 작용 횡력 tau_y = f3 = u3_N != 0  (지령은 0 인데!)
%  로그 검증: spare_five == u3_N, spare_four == N_res, 오차 정확히 0.
P.daisy_chain_active = true;
end
