%RUN_FINAL  최종 모델 확정 + val/test 정량평가 + XY 궤적 검증
%
%  ★ test 분할은 여기서 처음 사용한다 (선택은 전부 val 로 했다).
%  모델 2개를 끝까지 같이 보고한다:
%    D  : 23항 자유     — 5 s 기준 최적
%    F3 : m22 <= 3m 제약 — 장지평/물리타당성 우선 (RL 운동모델 납품본)

P = tug_params();
if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;
Zq = load('..\out\tug1_oe.mat');  Q = Zq.Q;
MD = struct('id',{'D','F3'},'Th',{Q(strcmp({Q.id},'D')).Th, Q(strcmp({Q.id},'F3')).Th}, ...
            'th',{Q(strcmp({Q.id},'D')).th, Q(strcmp({Q.id},'F3')).th}, ...
            'nm',{Q(strcmp({Q.id},'D')).names{1}, Q(strcmp({Q.id},'F3')).names{1}});

NS = [1 5 25 50 100 150 250];
EE = struct([]);
fprintf('\n=== A. 분할별 롤아웃 (5 s 창 / 구간전체) ===\n');
fprintf('%-3s %-6s %-6s | %6s %6s %6s %6s %6s %6s | %6s %7s %7s %6s\n', ...
    'mdl','split','horiz','u','v','r','x','y','psi','zeta','ATE[m]','거리[m]','ATE/거리');
fprintf('%s\n', repmat('-',1,118));
for im = 1:2
  for sp = {'train','val','test'}
    for H = {5.0, []}
        o = struct('minseg_s',3.0,'horiz_s',H{1},'split',sp{1},'Nsteps',NS);
        E = tug_eval(MD(im).Th, runs, P, o);
        lab = 'seg'; if ~isempty(H{1}), lab = sprintf('%.0fs',H{1}); end
        fprintf('%-3s %-6s %-6s | %6.3f %6.3f %6.3f %6.3f %6.3f %6.3f | %6.4f %7.3f %7.2f %6.3f\n', ...
            MD(im).id, sp{1}, lab, E.rmse, E.zeta, E.ate, E.dist_w, E.ate_rel);
        EE(im).(sp{1}).(sprintf('h%s',lab(1))) = E;
    end
  end
  fprintf('%s\n', repmat('-',1,118));
end

%% N-step 오차곡선 (test, 구간전체 롤아웃에서 집계)
fprintf('\n=== B. N-step 예측오차 곡선 (test) ===\n');
fprintf('%-3s %6s | %8s %8s %8s %8s %8s %8s\n','mdl','N[step]','u','v','r','x','y','psi');
for im = 1:2
    E = EE(im).test.hs;
    for q = 1:numel(E.Nsteps)
        fprintf('%-3s %6d | %8.4f %8.4f %8.4f %8.4f %8.4f %8.4f   (n=%d)\n', ...
            MD(im).id, E.Nsteps(q), E.curve(q,:), E.curve_n(q));
    end
end

%% 기동종류별 (test, 5 s 창)
fprintf('\n=== C. 기동종류별 성능 (test, 5 s 창) ===\n');
fprintf('%-16s %4s | %6s %6s %6s | %7s %7s | %6s %6s\n', ...
    'type','n','rmse_u','rmse_v','rmse_r','rmse_x','ATE_D','ATE_F3','zeta?');
for im = 1:2
    E = EE(im).test.h5;  pr = E.per;
    tp = unique({pr.type});
    if im==1, PRD = pr; else, PRF = pr; end
end
tp = unique({PRD.type});
fprintf('%-16s %4s | %6s %6s %6s %6s | %7s %7s\n','type','n','u','v','r','x','ATE_D','ATE_F3');
for i = 1:numel(tp)
    kD = strcmp({PRD.type}, tp{i});  kF = strcmp({PRF.type}, tp{i});
    rD = mean(cat(1,PRD(kD).rmse),1);
    fprintf('%-16s %4d | %6.3f %6.3f %6.3f %6.3f | %7.3f %7.3f\n', tp{i}, sum(kD), ...
        rD(1),rD(2),rD(3),rD(4), mean([PRD(kD).ate]), mean([PRF(kF).ate]));
end

%% ---------------- D. XY 궤적 그림 (test, 구간전체 롤아웃) ----------------
tpAll = unique({PRD.type});
sel = [];
for i = 1:numel(tpAll)
    best = 0;  bi = 0;
    for ir = 1:numel(runs)
        R = runs(ir).R;
        if ~strcmp(R.split,'test') || ~strcmp(R.type,tpAll{i}), continue, end
        if R.dur > best, best = R.dur; bi = ir; end
    end
    if bi>0, sel(end+1) = bi; end                                   %#ok<AGROW>
end

f = figure('Position',[60 40 1500 880],'Color','w');
tl = tiledlayout(f, 2, ceil(numel(sel)/2), 'TileSpacing','compact','Padding','compact');
for s = 1:numel(sel)
    R = runs(sel(s)).R;
    sg = tug_segs(R.act, round(3.0/P.Ts));
    [~, ib] = max(sg(:,2)-sg(:,1));  a = sg(ib,1); b = sg(ib,2);
    Zm = [R.u(a:b), R.v(a:b), R.r(a:b), R.x(a:b), R.y(a:b), R.psi(a:b)];
    p0 = Zm(1,6);  dX = Zm(:,4)-Zm(1,4);  dY = Zm(:,5)-Zm(1,5);
    Zm(:,4)= cos(p0)*dX + sin(p0)*dY;  Zm(:,5)= -sin(p0)*dX + cos(p0)*dY;
    Zm(:,6)= Zm(:,6)-p0;
    x0 = [Zm(1,1:3) 0 0 0];
    YD = tug_sim(MD(1).Th, R.tau(a:b,:), P.Ts, x0, P.la);
    YF = tug_sim(MD(2).Th, R.tau(a:b,:), P.Ts, x0, P.la);
    nexttile; hold on; grid on; axis equal
    plot(Zm(:,5), Zm(:,4), 'k-', 'LineWidth',2.2);
    plot(YD(:,5), YD(:,4), '-',  'Color',[0.85 0.33 0.10],'LineWidth',1.4);
    plot(YF(:,5), YF(:,4), '--', 'Color',[0.00 0.45 0.74],'LineWidth',1.4);
    plot(Zm(1,5),Zm(1,4),'ko','MarkerFaceColor','g','MarkerSize',7);
    eD = mean(sqrt((YD(:,4)-Zm(:,4)).^2+(YD(:,5)-Zm(:,5)).^2));
    eF = mean(sqrt((YF(:,4)-Zm(:,4)).^2+(YF(:,5)-Zm(:,5)).^2));
    title(sprintf('%s  (%.0f s)\nATE D %.2f / F3 %.2f m', ...
        strrep(R.type,'_','\_'), (b-a+1)*P.Ts, eD, eF), 'FontSize',9);
    xlabel('Y_{body0} [m]'); ylabel('X_{body0} [m]');
    if s==1, legend({'측정','D','F3'},'Location','best','FontSize',7); end
end
title(tl, 'Tug1 3-DOF 식별모델 — test 분할, 구간전체 완전재귀 롤아웃 XY 궤적', 'FontWeight','bold');
exportgraphics(f, '..\figs\tug1_test_xy.png', 'Resolution',150);

%% ---------------- E. 시계열 그림 (대표 3기동) ----------------
want = {'zigzag','turn_ccw','spin_cw'};
f2 = figure('Position',[60 40 1500 900],'Color','w');
tiledlayout(f2, 4, numel(want), 'TileSpacing','compact','Padding','compact');
Zs = cell(1,numel(want));
for s = 1:numel(want)
    ix = sel(strcmp(tpAll, want{s}));
    R = runs(ix).R;
    sg = tug_segs(R.act, round(3.0/P.Ts));  [~,ib]=max(sg(:,2)-sg(:,1));
    a=sg(ib,1); b=sg(ib,2);
    Zm = [R.u(a:b), R.v(a:b), R.r(a:b), R.x(a:b), R.y(a:b), R.psi(a:b)];
    p0=Zm(1,6); dX=Zm(:,4)-Zm(1,4); dY=Zm(:,5)-Zm(1,5);
    Zm(:,4)=cos(p0)*dX+sin(p0)*dY; Zm(:,5)=-sin(p0)*dX+cos(p0)*dY; Zm(:,6)=Zm(:,6)-p0;
    x0=[Zm(1,1:3) 0 0 0];
    YF = tug_sim(MD(2).Th, R.tau(a:b,:), P.Ts, x0, P.la);
    YD = tug_sim(MD(1).Th, R.tau(a:b,:), P.Ts, x0, P.la);
    Zs{s} = {Zm, YD, YF, (0:(b-a))'*P.Ts, R};
end
lbl = {'u [m/s]','v [m/s]','r [rad/s]','\psi [rad]'};
col = [1 2 3 6];
for row = 1:4
    for s = 1:numel(want)
        nexttile(( row-1)*numel(want)+s); hold on; grid on
        Zm=Zs{s}{1}; YD=Zs{s}{2}; YF=Zs{s}{3}; tt=Zs{s}{4};
        plot(tt, Zm(:,col(row)), 'k-','LineWidth',1.8);
        plot(tt, YD(:,col(row)), '-','Color',[0.85 0.33 0.10],'LineWidth',1.1);
        plot(tt, YF(:,col(row)), '--','Color',[0 0.45 0.74],'LineWidth',1.1);
        ylabel(lbl{row});
        if row==1, title(strrep(want{s},'_','\_'),'FontSize',10); end
        if row==4, xlabel('t [s]'); end
        if row==1 && s==1, legend({'측정','D','F3'},'Location','best','FontSize',7); end
    end
end
exportgraphics(f2, '..\figs\tug1_test_ts.png', 'Resolution',150);

%% ---------------- F. 파라미터 표 ----------------
fprintf('\n=== F. 식별 파라미터 ===\n');
nmU = unique([MD(1).nm, MD(2).nm],'stable');
fprintf('%-6s %12s %12s\n','term','D','F3');
for i=1:numel(nmU)
    g1 = NaN; g2 = NaN;
    j = strcmp(MD(1).nm, nmU{i}); if any(j), g1 = MD(1).th(j); end
    j = strcmp(MD(2).nm, nmU{i}); if any(j), g2 = MD(2).th(j); end
    fprintf('%-6s %12.4f %12.4f\n', nmU{i}, g1, g2);
end

save('..\out\tug1_final.mat','MD','EE','NS','-v7.3');
fprintf('\n저장: ..\\out\\tug1_final.mat, ..\\figs\\tug1_test_xy.png, ..\\figs\\tug1_test_ts.png\n');
