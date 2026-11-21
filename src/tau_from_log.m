function [tau, f, D] = tau_from_log(pwm_log, motor, P, T200)
%TAU_FROM_LOG  로그에서 "실제로 작용한" 추력/모멘트를 재구성한다.
%
%  [tau, f, D] = tau_from_log(pwm_log, motor, P, T200)
%
%  입력
%    pwm_log : [N x 3]  spare_one..three  [us]  실제 출력 PWM (포화 후)  <- 1차 경로
%    motor   : [N x 3]  motor1..3         [rad/s]  게이트/포화 '전' 지령 n  <- 교차검증용
%    P       : tug_params()
%    T200    : load('out/t200_18p5V.mat')
%
%  출력
%    tau : [N x 3]  실제 작용 [tau_x, tau_y, tau_N]   (N, N, N*m)
%    f   : [N x 3]  추진기별 추력 [f_left, f_right, f_bow]  [N]
%    D   : 진단 구조체
%
%  ─────────────────────────────────────────────────────────────────
%  ★ 왜 PWM 을 1차 경로로 쓰는가
%    ESC 가 실제로 받는 신호는 PWM 이다. 따라서 실제 추력은
%    f = (18.5 V 실측 PWM-추력 곡선)(PWM) 이 물리적으로 정확하다.
%    motor1..3 은 (a) 데드존 |n|<=33 적용 전, (b) PWM 포화 전 값이고,
%    (c) n->PWM 변환이 배달에서 빠진 otter_params_bow.m 의 룩업표에
%    의존한다. 실제로 motor 경유 경로는 로깅 PWM 을 최대 73 us 오차로
%    밖에 재현하지 못한다(= 모델 내부 표가 엑셀과 다르다).
%    물리는 PWM 이 결정하므로 PWM 을 쓴다.
%
%  ★ 왜 로깅된 taux/tauy/taun 을 쓰면 안 되는가
%    그것은 배분 '전' 지령이다. 특히 tauy_time_log 는 항상 0 이지만
%    (sway 스틱이 없다) 데이지체인이 선수추진기를 yaw 에 먼저 쓰므로
%    실제 작용 횡력은 tau_y = f_bow != 0 이고 측정상 최대 35.85 N 이다.
%    이것을 빠뜨리면 sway 방정식의 입력이 통째로 사라진다.
%  ─────────────────────────────────────────────────────────────────

narginchk(4,4);
pwm = double(pwm_log);
pwm = min(max(pwm, P.PWM_LO), P.PWM_HI);

% ---------- 1. PWM -> 추력 : 18.5 V 실측곡선 직접 보간 ----------
%  T200.pwm 은 4 us 격자로 단조증가, T200.f 는 PWM 에 대해 단조증가.
f = interp1(T200.pwm, T200.f, pwm, 'linear');
%  제조사 데드밴드 구간은 명시적으로 0 (보간 잔여값 제거)
db = pwm >= min(T200.pwm(T200.n==0)) & pwm <= max(T200.pwm(T200.n==0));
f(db) = 0;

% ---------- 2. f -> tau ----------
tau = f * P.T.';

% ---------- 3. 교차검증 A: 컨트롤러 2차모델 경로 ----------
%  n(PWM) 역변환 -> f = k n|n|. 컨트롤러가 '믿은' 추력.
n_inv = interp1(T200.pwm_uniq, T200.n_uniq, pwm, 'linear', 'extrap');
n_inv(db) = 0;
f_quad = zeros(size(n_inv));
ps = n_inv >= 0;
f_quad( ps) = P.k_pos_ctrl * n_inv( ps).*abs(n_inv( ps));
f_quad(~ps) = P.k_neg_ctrl * n_inv(~ps).*abs(n_inv(~ps));

% ---------- 4. 교차검증 B: motor1..3 경로 ----------
nm = double(motor);
nm(abs(nm) <= P.n_gate) = 0;                       % 모터 데드존 (gate)
nm = min(max(nm, T200.n_min), T200.n_max);         % PWM 포화와 등가
f_mot = zeros(size(nm));
ps = nm >= 0;
f_mot( ps) = P.k_pos_ctrl * nm( ps).*abs(nm( ps));
f_mot(~ps) = P.k_neg_ctrl * nm(~ps).*abs(nm(~ps));

% ---------- 5. 진단 ----------
D = struct();
D.f_quad_rms = sqrt(mean((f - f_quad).^2, 1));     % 실측곡선 vs 2차모델
D.f_mot_rms  = sqrt(mean((f - f_mot ).^2, 1));     % 실측곡선 vs 지령경로
D.sat_frac   = mean(pwm_log(:) <= P.PWM_LO+0.5 | pwm_log(:) >= P.PWM_HI-0.5);
D.db_frac    = mean(db(:));
D.f_range    = [min(f,[],1); max(f,[],1)];
D.tau_range  = [min(tau,[],1); max(tau,[],1)];
D.f_quad     = f_quad;
D.f_mot      = f_mot;
end
