function R = ulog2run(ulgPath, P, T200, opt)
%ULOG2RUN  ULog 1개 -> 식별용 균일격자 구조체
%
%  R = ulog2run(ulgPath, P, T200, opt)
%
%  opt.framelen (51) / opt.order (3)  : SG 미분 창
%  opt.trim_s   (0.3)                 : 제어 ON 구간 앞뒤 잘라내기 [s]
%  opt.raw      (true)                : 원시 uORB 교차검증 수행
%
%  상태 출처 = tug_log_data (온보드 Simulink 가 계산한 그 값).
%  나중에 같은 Simulink 모델에 모델을 붙일 것이므로 일관성을 위해 이것을 쓴다.
%    u,v : DCM(q)*v_NED 의 1,2 성분   (EKF2 속도 + 자세)
%    r   : vehicle_angular_velocity(3) (바디 FRD 직접)
%    x,y : lla2ned(GPS lat/lon, ref_lla)  <- vehicle_local_position 이 아니다
%    psi : quat -> euler 의 yaw
%  원시 토픽으로 재계산한 값과의 차이는 R.chk 에 기록한다 (v 추정 민감도).

if nargin < 4, opt = struct; end
if ~isfield(opt,'framelen'), opt.framelen = 51;  end
if ~isfield(opt,'order'),    opt.order    = 3;   end
if ~isfield(opt,'trim_s'),   opt.trim_s   = 0.3; end
if ~isfield(opt,'raw'),      opt.raw      = true; end

Ts = P.Ts;
R  = struct('file', ulgPath, 'ok', false, 'msg', '');

%% ---------- 1. 읽기 ----------
try
    ul = ulogreader(ulgPath);
catch ME
    R.msg = ['ulogreader 실패: ' ME.message];  return
end
L = readTopicMsgs(ul);                        % 전체 토픽 목록 + 메시지
getT = @(nm) local_get(L, nm);

TL = getT('tug_log_data');
if isempty(TL), R.msg = 'tug_log_data 없음'; return; end

t_raw = seconds(TL.timestamp);  t_raw = t_raw - t_raw(1);

%% ---------- 2. 균일격자 ----------
% 로그 dt 는 0.004~0.024 s 로 흔들린다 -> Ts 격자로 재표본
t = (0 : Ts : t_raw(end)).';
if numel(t) < 3*opt.framelen
    R.msg = sprintf('너무 짧다 (%.1f s)', t_raw(end)); return
end

% psi 는 보간 전에 unwrap (±pi 점프 제거)
psi_raw = unwrap(double(TL.psi_time_log));

ipl = @(y)        interp1(t_raw, double(y), t, 'linear', 'extrap');
ipn = @(y) double(interp1(t_raw, double(y), t, 'nearest','extrap'));

u   = ipl(TL.u_time_log);    v   = ipl(TL.v_time_log);    r = ipl(TL.r_time_log);
x   = ipl(TL.x_time_log);    y   = ipl(TL.y_time_log);    psi = ipl(psi_raw);
tcx = ipl(TL.taux_time_log); tcy = ipl(TL.tauy_time_log); tcn = ipl(TL.taun_time_log);
mot = [ipl(TL.motor1_time_log), ipl(TL.motor2_time_log), ipl(TL.motor3_time_log)];
pwm = [ipl(TL.spare_one), ipl(TL.spare_two), ipl(TL.spare_three)];
Nres = ipl(TL.spare_four);   u3N = ipl(TL.spare_five);
rcon = ipn(TL.rc_on_off);    onof = ipn(TL.on_off);

%% ---------- 3. 실제 작용 tau 재구성 ----------
[tau, fth, Dtau] = tau_from_log(pwm, mot, P, T200);

%% ---------- 4. 데이지체인 정합성 (지령 -> 선수추진기) ----------
%  ★ clamp 는 비선형이므로 반드시 '원시격자'에서 비교한다.
%    재표본 후 비교하면 interp(clamp(x)) ~= clamp(interp(x)) 로 가짜 오차가 난다.
tcn_r  = double(TL.taun_time_log);
u3N_r  = min(max(tcn_r/P.la, P.f3_min), P.f3_max);
R.chk.u3N_err  = max(abs(u3N_r              - double(TL.spare_five)));
R.chk.Nres_err = max(abs(tcn_r - P.la*u3N_r - double(TL.spare_four)));
R.chk.tauy_cmd_max = max(abs(double(TL.tauy_time_log)));

%% ---------- 5. 유효구간 마스크 ----------
act = rcon > 0.5 & onof > 0.5;
% 앞뒤 trim (스틱 진입/이탈 과도 + SG 경계)
k = max(1, round(opt.trim_s/Ts));
act = act & [false(k,1); act(1:end-k)] & [act(k+1:end); false(k,1)];

%% ---------- 6. SG 평활 + 가속도 ----------
[us, du] = sg_diff(u,   Ts, opt.framelen, opt.order);
[vs, dv] = sg_diff(v,   Ts, opt.framelen, opt.order);
[rs, dr] = sg_diff(r,   Ts, opt.framelen, opt.order);

%% ---------- 7. 원시 토픽 교차검증 ----------
R.chk.v_rms_diff = NaN;  R.chk.r_rms_diff = NaN;
R.chk.volt = [NaN NaN];  R.chk.gps_fix = NaN;  R.chk.gps_eph = NaN;
R.chk.acc_rms_diff = NaN;  R.chk.pitch_deg = [NaN NaN];
if opt.raw
    BS = getT('battery_status');
    if ~isempty(BS) && any(strcmp('voltage_v', BS.Properties.VariableNames))
        vv = double(BS.voltage_v);  R.chk.volt = [min(vv) max(vv)];
    end
    GP = getT('vehicle_gps_position');
    if ~isempty(GP)
        vn = GP.Properties.VariableNames;
        if any(strcmp('fix_type',vn)), R.chk.gps_fix = min(double(GP.fix_type)); end
        if any(strcmp('eph',vn)),      R.chk.gps_eph = max(double(GP.eph));      end
    end
    % u,v 를 vehicle_local_position + vehicle_attitude 로 독립 재계산
    LP = getT('vehicle_local_position');  AT = getT('vehicle_attitude');
    if ~isempty(AT)
        ta = seconds(AT.timestamp); ta = ta - ta(1);
        q  = double(AT.q);
    end
    if ~isempty(LP) && ~isempty(AT)
        tl = seconds(LP.timestamp); tl = tl - tl(1);
        vN = interp1(tl, double(LP.vx), t, 'linear','extrap');
        vE = interp1(tl, double(LP.vy), t, 'linear','extrap');
        psi_q = unwrap(atan2(2*(q(:,1).*q(:,4)+q(:,2).*q(:,3)), ...
                             1-2*(q(:,3).^2+q(:,4).^2)));
        ps = interp1(ta, psi_q, t, 'linear','extrap');
        u2 =  vN.*cos(ps) + vE.*sin(ps);
        v2 = -vN.*sin(ps) + vE.*cos(ps);
        m2 = act;
        if any(m2)
            R.chk.u_rms_diff = sqrt(mean((u2(m2)-u(m2)).^2));
            R.chk.v_rms_diff = sqrt(mean((v2(m2)-v(m2)).^2));
            R.chk.psi_rms_diff = sqrt(mean(wrapToPi(ps(m2)-psi(m2)).^2));
        end
    end
    % 바디 가속도 (IMU) vs SG 미분
    AC = getT('vehicle_acceleration');
    if ~isempty(AC) && any(strcmp('xyz', AC.Properties.VariableNames)) && ~isempty(AT)
        tc = seconds(AC.timestamp); tc = tc - tc(1);
        ax = interp1(tc, double(AC.xyz(:,1)), t, 'linear','extrap');
        %  ★ vehicle_acceleration 은 '비력(specific force)' 이라 중력이 섞여 있다.
        %     a_meas = a_kin_body - g_body,   g_body = R(NED<-body)' * [0;0;g]
        %     g_body_x = g*R(3,1) = -g*sin(theta)   (theta = pitch)
        %     => a_kin_x = a_meas_x - g*sin(theta)
        %     운동학 바디 가속도는 구심항을 포함: a_kin_x = du - v*r
        R31 = 2*(q(:,2).*q(:,4) - q(:,1).*q(:,3));       % = -sin(theta)
        th  = asin(max(min(-R31,1),-1));                  % pitch [rad]
        thi = interp1(ta, th, t, 'linear','extrap');
        if any(act)
            R.chk.acc_rms_diff = sqrt(mean( ...
                ((ax(act) - P.g*sin(thi(act))) - (du(act)-vs(act).*rs(act))).^2));
            R.chk.pitch_deg = [min(rad2deg(thi(act))) max(rad2deg(thi(act)))];
        end
    end
end

%% ---------- 8. 출력 ----------
R.ok   = true;
R.t    = t;      R.act = act;
R.u    = us;     R.v  = vs;   R.r  = rs;
R.du   = du;     R.dv = dv;   R.dr = dr;
R.u_m  = u;      R.v_m = v;   R.r_m = r;        % 평활 전 원값
R.x    = x;      R.y  = y;    R.psi = psi;      % psi 는 unwrap 상태
R.tau  = tau;    R.f  = fth;
R.tau_cmd = [tcx tcy tcn];
R.pwm  = pwm;    R.motor = mot;
R.Dtau = Dtau;
R.dur  = t(end);
R.n_act = sum(act);
end

% ================================================================
function TT = local_get(L, name)
TT = [];
idx = find(strcmp(L.TopicNames, name), 1);
if isempty(idx), return; end
TT = L.TopicMessages{idx};
end
