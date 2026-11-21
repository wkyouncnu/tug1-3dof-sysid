%RUN_SLX_VAL  PWM 입력 Simulink 운동모델을 '밸리데이션' 로그로 검증한다.
%
%  ---------------------------------------------------------------
%  무엇을 하는가
%  ---------------------------------------------------------------
%  ① 밸리데이션 분할(식별에 쓰지 않은 로그)만 골라낸다
%  ② 각 로그의 실측 PWM(spare_one/two/three) 을 그대로 tug1_3dof_pwm.slx 에
%     넣는다. 모델 내부에서 T200 18.5 V PWM-추력 곡선 -> 추력배분 -> 동역학
%  ③ 완전재귀 롤아웃(측정 피드백 없음) 궤적을 로그와 정량 비교
%  ④ PWM 입력판 vs tau 입력판(tug_sim, 식별에 쓴 경로) 차이도 함께 보고
%  ⑤ 로그 자체를 눈으로 볼 수 있게 PWM / 복원 tau / 상태 시계열을 그린다
%
%  ★ 왜 '밸리데이션' 인가
%  식별(train)에 쓴 로그로 궤적이 맞는 건 당연하다. 쓰지 않은 로그에서
%  같은 PWM -> 같은 궤적이 나와야 RL 환경으로 쓸 수 있다.
%
%  ★ PWM 입력판과 tau 입력판의 불가피한 차이
%  식별 파이프라인은 PWM 을 50 Hz 격자로 선형보간한 뒤 tau 를 계산했고,
%  tug_sim 은 RK4 중간스텝에서 'tau' 를 선형보간한다. 이 모델은 'PWM' 을
%  보간한 뒤 비선형 룩업을 통과시키므로 중간스텝 값이 미세하게 다르다
%  (데드밴드 경계에서 최대). 아래 D 열이 그 크기다.
%
%  산출물: ..\out\tug1_slxval.mat, ..\figs\tug1_val_slx_xy.png,
%          ..\figs\tug1_val_slx_ts.png, ..\figs\tug1_val_slx_log.png

P   = tug_params();
T200 = load('..\out\t200_18p5V.mat');
T200_PWM = T200.pwm(:);                                     %#ok<NASGU>
T200_F   = T200.f(:);                                       %#ok<NASGU>

if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;
MDL  = tug1_model();

mdl = 'tug1_3dof_pwm';
if ~bdIsLoaded(mdl)
    if isfile(fullfile('..','out',[mdl '.slx']))
        load_system(fullfile('..','out',[mdl '.slx']));
    else
        build_tug1_pwm_slx(mdl);
    end
end
set_param([mdl '/YSIM'], 'SampleTime', sprintf('%.10g', P.Ts));

ids  = {'D','F3'};
iv   = find(arrayfun(@(z) strcmp(z.R.split,'val'), runs));
nv   = numel(iv);

% ---------------------------------------------------------------
% 0. 밸리데이션 로그 목록 (사용자가 로그 자체를 확인할 수 있게)
% ---------------------------------------------------------------
fprintf('\n=== 밸리데이션 로그 %d개 (식별에 쓰지 않은 데이터) ===\n', nv);
fprintf('%-3s %-40s %-14s %7s %7s | %8s %8s %8s | %7s %7s\n', ...
    '#','파일','기동','dur[s]','seg[s]','maxPWM','minPWM','db%','max|u|','max|r|');
fprintf('%s\n', repmat('-',1,125));

SEG = zeros(nv,2);
for k = 1:nv
    R  = runs(iv(k)).R;
    sg = tug_segs(R.act, round(3.0/P.Ts));
    [~, ib] = max(sg(:,2)-sg(:,1));
    SEG(k,:) = [sg(ib,1) sg(ib,2)];
    a = SEG(k,1); b = SEG(k,2);
    pw = R.pwm(a:b,:);
    dbf = mean(pw(:) >= min(T200.pwm(T200.n==0)) & pw(:) <= max(T200.pwm(T200.n==0)));
    fprintf('%-3d %-40s %-14s %7.1f %7.1f | %8.0f %8.0f %7.1f | %7.3f %7.3f\n', ...
        k, R.name, R.type, R.dur, (b-a)*P.Ts, max(pw(:)), min(pw(:)), 100*dbf, ...
        max(abs(R.u(a:b))), max(abs(R.r(a:b))));
end

% ---------------------------------------------------------------
% 1. 각 로그마다 Simulink(PWM 입력) 롤아웃 + 정량 비교
% ---------------------------------------------------------------
sd = [std(cell2mat(arrayfun(@(z) z.R.u, runs(iv), 'uni',0)')), ...
      std(cell2mat(arrayfun(@(z) z.R.v, runs(iv), 'uni',0)')), ...
      std(cell2mat(arrayfun(@(z) z.R.r, runs(iv), 'uni',0)'))];
sd = [sd, 1, 1, 1];                      % 위치/방위는 절대값으로 본다

RES = struct();
for k = 1:numel(ids)
    RES(k).id = ids{k};
    RES(k).rmse = zeros(nv,6);
    RES(k).ate  = zeros(nv,1);
    RES(k).fin  = zeros(nv,1);
    RES(k).dist = zeros(nv,1);
    RES(k).dpwm = zeros(nv,6);           % PWM 입력판 vs tau 입력판 차이
end

for k = 1:numel(ids)
    TUG1_P = MDL.(ids{k}).p;                                %#ok<NASGU>
    for s = 1:nv
        R = runs(iv(s)).R;  a = SEG(s,1); b = SEG(s,2);
        L = b-a+1;  t = (0:L-1)'*P.Ts;

        x0 = [R.u(a), R.v(a), R.r(a), 0, 0, 0];
        TUG1_X0 = x0(:);                                    %#ok<NASGU>
        PWM_TS  = timeseries(R.pwm(a:b,:), t);              %#ok<NASGU>

        so = sim(mdl, 'StopTime', sprintf('%.10g',(L-1)*P.Ts));
        Ys = so.get('YSIM');
        if isa(Ys,'timeseries'), Ys = Ys.Data; end
        if ndims(Ys) == 3, Ys = permute(squeeze(Ys), [2 1]); end
        n = min(size(Ys,1), L);  Ys = Ys(1:n,:);

        % tau 입력판(식별에 쓴 경로) — 차이 정량화용
        Yt = tug_sim(MDL.(ids{k}).Th, R.tau(a:b,:), P.Ts, x0, P.la);
        RES(k).dpwm(s,:) = max(abs(Ys - Yt(1:n,:)), [], 1);

        % 로그: 창 시작 바디프레임으로 회전 (롤아웃은 psi0=0 에서 출발)
        p0 = R.psi(a);
        dX = R.x(a:a+n-1) - R.x(a);  dY = R.y(a:a+n-1) - R.y(a);
        Zm = [R.u(a:a+n-1), R.v(a:a+n-1), R.r(a:a+n-1), ...
               cos(p0)*dX + sin(p0)*dY, -sin(p0)*dX + cos(p0)*dY, ...
               R.psi(a:a+n-1) - p0];

        E = Ys - Zm;
        RES(k).rmse(s,:) = sqrt(mean(E.^2, 1));
        pe = hypot(E(:,4), E(:,5));
        RES(k).ate(s)  = sqrt(mean(pe.^2));
        RES(k).fin(s)  = pe(end);
        RES(k).dist(s) = sum(hypot(diff(Zm(:,4)), diff(Zm(:,5))));

        if k == 1 && s == 1, YS1 = Ys; ZM1 = Zm; end
    end
end

% ---------------------------------------------------------------
% 2. 로그별 성능표
% ---------------------------------------------------------------
for k = 1:numel(ids)
    fprintf('\n=== [%s] 밸리데이션 로그별 Simulink(PWM 입력) 궤적 성능 ===\n', ids{k});
    fprintf('%-3s %-14s %6s | %6s %6s %6s %6s %6s %6s | %7s %7s %7s %7s | %8s\n', ...
        '#','기동','T[s]','rmsU','rmsV','rmsR','rmsX','rmsY','rmsPsi', ...
        'ATE','최종err','주행','ATE/주행','d(PWM-tau)');
    fprintf('%s\n', repmat('-',1,135));
    Rk = RES(k);
    for s = 1:nv
        R = runs(iv(s)).R;
        fprintf('%-3d %-14s %6.1f | %6.3f %6.3f %6.3f %6.3f %6.3f %6.3f | %7.3f %7.3f %7.2f %7.3f | %8.1e\n', ...
            s, R.type, (SEG(s,2)-SEG(s,1))*P.Ts, Rk.rmse(s,:), ...
            Rk.ate(s), Rk.fin(s), Rk.dist(s), Rk.ate(s)/max(Rk.dist(s),eps), ...
            max(Rk.dpwm(s,4:5)));
    end
    fprintf('%s\n', repmat('-',1,135));
    zeta = mean(Rk.rmse(:,1:3) ./ sd(1:3), 2);
    fprintf('%-18s %6.1f | %6.3f %6.3f %6.3f %6.3f %6.3f %6.3f | %7.3f %7.3f %7.2f %7.3f | %8.1e\n', ...
        '평균', mean((SEG(:,2)-SEG(:,1))*P.Ts), mean(Rk.rmse,1), ...
        mean(Rk.ate), mean(Rk.fin), mean(Rk.dist), mean(Rk.ate./max(Rk.dist,eps)), ...
        max(Rk.dpwm(:,4:5),[],'all'));
    fprintf('속도 정규화 지표 zeta = mean(rmse_uvr/sd_uvr) : 평균 %.4f (중앙 %.4f, 최악 %.4f)\n', ...
        mean(zeta), median(zeta), max(zeta));
    RES(k).zeta = zeta;
end

% ---------------------------------------------------------------
% 3. 기동 종류별 집계
% ---------------------------------------------------------------
typ = unique(arrayfun(@(z) string(z.R.type), runs(iv)));
fprintf('\n=== 기동 종류별 집계 (밸리데이션, Simulink PWM 입력) ===\n');
fprintf('%-14s %4s |', '기동', 'n');
for k = 1:numel(ids), fprintf(' %8s %8s %8s |', [ids{k} '.ATE'], [ids{k} '.fin'], [ids{k} '.rel']); end
fprintf('\n%s\n', repmat('-',1,22+30*numel(ids)));
TY = zeros(numel(typ), 3*numel(ids));
for i = 1:numel(typ)
    m = arrayfun(@(z) strcmp(z.R.type, typ(i)), runs(iv));
    fprintf('%-14s %4d |', typ(i), sum(m));
    for k = 1:numel(ids)
        v = [mean(RES(k).ate(m)), mean(RES(k).fin(m)), ...
             mean(RES(k).ate(m)./max(RES(k).dist(m),eps))];
        TY(i,(k-1)*3+(1:3)) = v;
        fprintf(' %8.3f %8.3f %8.3f |', v);
    end
    fprintf('\n');
end

% ---------------------------------------------------------------
% 4. XY 궤적 그림 — 종류별 가장 긴 밸리데이션 로그
% ---------------------------------------------------------------
pick = zeros(numel(typ),1);
for i = 1:numel(typ)
    best = -1;
    for s = 1:nv
        if ~strcmp(runs(iv(s)).R.type, typ(i)), continue, end
        d = SEG(s,2)-SEG(s,1);
        if d > best, best = d; pick(i) = s; end
    end
end

fh = figure('Position',[60 40 1500 950],'Color','w');
tl = tiledlayout(fh, 3, ceil(numel(pick)/3), 'TileSpacing','compact','Padding','compact');
title(tl, 'Simulink(PWM 입력) vs 로그 — 밸리데이션 분할 XY 궤적', 'FontWeight','bold');
for i = 1:numel(pick)
    s = pick(i); R = runs(iv(s)).R; a = SEG(s,1); b = SEG(s,2);
    L = b-a+1; t = (0:L-1)'*P.Ts;
    p0 = R.psi(a);
    dX = R.x(a:b)-R.x(a); dY = R.y(a:b)-R.y(a);
    xm =  cos(p0)*dX + sin(p0)*dY;  ym = -sin(p0)*dX + cos(p0)*dY;

    ax = nexttile(tl); hold(ax,'on'); grid(ax,'on'); axis(ax,'equal');
    plot(ax, ym, xm, 'k-', 'LineWidth',2.0);
    leg = {'로그'};
    co = [0.85 0.33 0.10; 0.00 0.45 0.74];
    for k = 1:numel(ids)
        TUG1_P = MDL.(ids{k}).p;                            %#ok<NASGU>
        TUG1_X0 = [R.u(a) R.v(a) R.r(a) 0 0 0]';            %#ok<NASGU>
        PWM_TS  = timeseries(R.pwm(a:b,:), t);              %#ok<NASGU>
        so = sim(mdl,'StopTime',sprintf('%.10g',(L-1)*P.Ts));
        Ys = so.get('YSIM'); if ndims(Ys)==3, Ys = permute(squeeze(Ys),[2 1]); end
        plot(ax, Ys(:,5), Ys(:,4), '-', 'Color',co(k,:), 'LineWidth',1.4);
        leg{end+1} = ids{k};                                %#ok<SAGROW>
    end
    plot(ax, 0, 0, 'ko','MarkerFaceColor','g','MarkerSize',7);
    title(ax, sprintf('%s  (%.0f s)  ATE %.2f/%.2f m', strrep(char(typ(i)),'_','\_'), ...
        (b-a)*P.Ts, RES(1).ate(s), RES(2).ate(s)), 'FontSize',9);
    xlabel(ax,'y_{body0} [m]'); ylabel(ax,'x_{body0} [m]');
    if i == 1, legend(ax, leg, 'Location','best','FontSize',7); end
end
exportgraphics(fh, '..\figs\tug1_val_slx_xy.png', 'Resolution',150);
fprintf('\n저장: ..\\figs\\tug1_val_slx_xy.png\n');

% ---------------------------------------------------------------
% 5. 시계열 — 대표 3개 (zigzag / turn / spin)
% ---------------------------------------------------------------
want = {'zigzag','turn_ccw','spin_cw'};
p3 = [];
for i = 1:numel(want)
    j = find(strcmp(string(typ), want{i}), 1);
    if ~isempty(j), p3(end+1) = pick(j); end                %#ok<SAGROW>
end
lbl = {'u [m/s]','v [m/s]','r [rad/s]','x [m]','y [m]','\psi [rad]'};
fh2 = figure('Position',[60 40 1500 950],'Color','w');
tl2 = tiledlayout(fh2, 6, numel(p3), 'TileSpacing','compact','Padding','compact');
title(tl2,'Simulink(PWM 입력) vs 로그 — 밸리데이션 시계열','FontWeight','bold');
for c = 1:numel(p3)
    s = p3(c); R = runs(iv(s)).R; a = SEG(s,1); b = SEG(s,2);
    L = b-a+1; t = (0:L-1)'*P.Ts;
    p0 = R.psi(a);
    dX = R.x(a:b)-R.x(a); dY = R.y(a:b)-R.y(a);
    Zm = [R.u(a:b), R.v(a:b), R.r(a:b), cos(p0)*dX+sin(p0)*dY, ...
          -sin(p0)*dX+cos(p0)*dY, R.psi(a:b)-p0];
    YY = cell(1,numel(ids));
    for k = 1:numel(ids)
        TUG1_P = MDL.(ids{k}).p;                            %#ok<NASGU>
        TUG1_X0 = [R.u(a) R.v(a) R.r(a) 0 0 0]';            %#ok<NASGU>
        PWM_TS  = timeseries(R.pwm(a:b,:), t);              %#ok<NASGU>
        so = sim(mdl,'StopTime',sprintf('%.10g',(L-1)*P.Ts));
        Ys = so.get('YSIM'); if ndims(Ys)==3, Ys = permute(squeeze(Ys),[2 1]); end
        YY{k} = Ys;
    end
    for ch = 1:6
        ax = nexttile(tl2, (ch-1)*numel(p3)+c); hold(ax,'on'); grid(ax,'on');
        plot(ax, t, Zm(:,ch), 'k-','LineWidth',1.6);
        plot(ax, t(1:size(YY{1},1)), YY{1}(:,ch), '-','Color',[0.85 0.33 0.10]);
        plot(ax, t(1:size(YY{2},1)), YY{2}(:,ch), '-','Color',[0.00 0.45 0.74]);
        if ch == 1, title(ax, strrep(R.type,'_','\_'),'FontSize',9); end
        if c == 1, ylabel(ax, lbl{ch},'FontSize',8); end
        if ch == 6, xlabel(ax,'t [s]','FontSize',8); end
        if ch==1 && c==1, legend(ax,{'로그',ids{1},ids{2}},'Location','best','FontSize',7); end
    end
end
exportgraphics(fh2, '..\figs\tug1_val_slx_ts.png', 'Resolution',150);
fprintf('저장: ..\\figs\\tug1_val_slx_ts.png\n');

% ---------------------------------------------------------------
% 6. 로그 원본 확인용 — PWM 3채널 + 복원 tau 3채널
% ---------------------------------------------------------------
fh3 = figure('Position',[60 40 1500 800],'Color','w');
tl3 = tiledlayout(fh3, 3, numel(p3), 'TileSpacing','compact','Padding','compact');
title(tl3,'밸리데이션 로그 원본 — 실측 PWM 과 그로부터 복원한 tau','FontWeight','bold');
nmP = {'좌현(spare\_one)','우현(spare\_two)','바우(spare\_three)'};
for c = 1:numel(p3)
    s = p3(c); R = runs(iv(s)).R; a = SEG(s,1); b = SEG(s,2);
    t = (0:(b-a))'*P.Ts;
    ax = nexttile(tl3, c); hold(ax,'on'); grid(ax,'on');
    plot(ax, t, R.pwm(a:b,:), 'LineWidth',1.1);
    yline(ax, P.PWM_MID, 'k:');
    title(ax, sprintf('%s — PWM [us]', strrep(R.type,'_','\_')),'FontSize',9);
    if c==1, ylabel(ax,'PWM [\mus]'); legend(ax, nmP,'Location','best','FontSize',7); end

    ax = nexttile(tl3, numel(p3)+c); hold(ax,'on'); grid(ax,'on');
    plot(ax, t, R.tau(a:b,:), 'LineWidth',1.1);
    if c==1, ylabel(ax,'복원 \tau [N, N, Nm]'); legend(ax,{'\tau_x','\tau_y','\tau_N'},'Location','best','FontSize',7); end
    title(ax,'PWM -> T200 곡선 -> 추력배분','FontSize',9);

    ax = nexttile(tl3, 2*numel(p3)+c); hold(ax,'on'); grid(ax,'on');
    plot(ax, t, R.tau_cmd(a:b,:), 'LineWidth',1.1);
    if c==1, ylabel(ax,'로그 \tau 지령 (배분 전)'); legend(ax,{'taux','tauy','taun'},'Location','best','FontSize',7); end
    title(ax,'★ tauy == 0 (스웨이 스틱 없음)','FontSize',9);
    xlabel(ax,'t [s]');
end
exportgraphics(fh3, '..\figs\tug1_val_slx_log.png', 'Resolution',150);
fprintf('저장: ..\\figs\\tug1_val_slx_log.png\n');

% ---------------------------------------------------------------
% 7. PWM 입력판 vs tau 입력판 — 경로 차이 요약
% ---------------------------------------------------------------
fprintf('\n=== PWM 입력판 vs tau 입력판(식별 경로) 최대 편차 ===\n');
fprintf('%-4s | %10s %10s %10s %10s %10s %10s\n','mdl','du','dv','dr','dx','dy','dpsi');
for k = 1:numel(ids)
    fprintf('%-4s | %10.3e %10.3e %10.3e %10.3e %10.3e %10.3e\n', ...
        ids{k}, max(RES(k).dpwm,[],1));
end
fprintf('→ 위 값이 궤적오차(ATE 수십 cm~m)보다 2~3 자리 작으면 두 경로는 사실상 같다.\n');

% ---------------------------------------------------------------
% 8. 지평(horizon) 스윕 — H 초마다 초기화하는 창 롤아웃
%    위 1~7 은 '한 번 초기화하고 끝까지' 가는 최악 조건이다. RL 환경은
%    에피소드마다 초기화되고 제어기가 루프를 닫으므로 짧은 지평 성능이
%    실제로 중요하다. 같은 Simulink(PWM 입력) 모델로 측정한다.
% ---------------------------------------------------------------
HS = [2 5 10];
HZ = zeros(numel(HS), 6, numel(ids));   % rmse 6채널
HA = zeros(numel(HS), 2, numel(ids));   % [ATE, nwin]
for k = 1:numel(ids)
    TUG1_P = MDL.(ids{k}).p;                                %#ok<NASGU>
    for ih = 1:numel(HS)
        Lh = round(HS(ih)/P.Ts) + 1;
        acc = zeros(1,6); npt = 0; ae = 0; naw = 0;
        for s = 1:nv
            R = runs(iv(s)).R; a0 = SEG(s,1); b0 = SEG(s,2);
            for a = a0:Lh-1:(b0-Lh+1)
                b = a + Lh - 1;
                t = (0:Lh-1)'*P.Ts;
                TUG1_X0 = [R.u(a) R.v(a) R.r(a) 0 0 0]';    %#ok<NASGU>
                PWM_TS  = timeseries(R.pwm(a:b,:), t);      %#ok<NASGU>
                so = sim(mdl,'StopTime',sprintf('%.10g',(Lh-1)*P.Ts));
                Ys = so.get('YSIM'); if ndims(Ys)==3, Ys = permute(squeeze(Ys),[2 1]); end
                n = min(size(Ys,1), Lh); Ys = Ys(1:n,:);
                p0 = R.psi(a);
                dX = R.x(a:a+n-1)-R.x(a); dY = R.y(a:a+n-1)-R.y(a);
                Zm = [R.u(a:a+n-1), R.v(a:a+n-1), R.r(a:a+n-1), ...
                      cos(p0)*dX+sin(p0)*dY, -sin(p0)*dX+cos(p0)*dY, R.psi(a:a+n-1)-p0];
                E = Ys - Zm;
                acc = acc + sum(E.^2,1); npt = npt + n;
                ae  = ae + mean(hypot(E(:,4),E(:,5)).^2); naw = naw + 1;
            end
        end
        HZ(ih,:,k) = sqrt(acc/max(npt,1));
        HA(ih,:,k) = [sqrt(ae/max(naw,1)), naw];
    end
end
fprintf('\n=== 지평별 성능 (H 초마다 초기화, Simulink PWM 입력, 밸리데이션) ===\n');
fprintf('%-4s %5s %5s | %6s %6s %6s %6s %6s %6s | %7s %7s\n', ...
    'mdl','H[s]','창수','rmsU','rmsV','rmsR','rmsX','rmsY','rmsPsi','ATE','zeta');
fprintf('%s\n', repmat('-',1,88));
for k = 1:numel(ids)
    for ih = 1:numel(HS)
        z = mean(HZ(ih,1:3,k)./sd(1:3));
        fprintf('%-4s %5.0f %5.0f | %6.3f %6.3f %6.3f %6.3f %6.3f %6.3f | %7.3f %7.4f\n', ...
            ids{k}, HS(ih), HA(ih,2,k), HZ(ih,:,k), HA(ih,1,k), z);
    end
end

save('..\out\tug1_slxval.mat','RES','ids','iv','SEG','TY','typ','sd','HS','HZ','HA','-v7.3');
fprintf('\n저장: ..\\out\\tug1_slxval.mat\n');
