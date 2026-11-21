%CHECK_SLX  Simulink 운동모델 == MATLAB 롤아웃(tug_sim) 수치 일치 검증
%
%  ★ 왜 이 검증이 필요한가
%  식별/평가는 전부 MATLAB 의 tug_sim (RK4, 완전재귀) 로 했다. 나중에 RL 환경을
%  Simulink 로 쓸 때 '같은 모델' 이 아니면 평가 결과가 무의미해진다.
%  따라서 동일 tau 입력에 대해 두 경로가 수치적으로 일치하는지 확인한다.
%
%  ★ 일치 조건
%  tug_sim 의 RK4 는 중간스텝에서 tm = 0.5*(t1+t2) 의 tau 를 '선형보간' 해서 쓴다.
%  Simulink 쪽도 From Workspace 의 보간을 켜야(ZOH 금지) 같아진다.
%  솔버는 fixed-step ode4, h = Ts = 0.02 s.

P  = tug_params();
if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;

MDL = tug1_model();                       % D / F3 파라미터 벡터

mdl = 'tug1_3dof';
if ~bdIsLoaded(mdl)
    if isfile(fullfile('..','out',[mdl '.slx']))
        load_system(fullfile('..','out',[mdl '.slx']));
    else
        build_tug1_slx(mdl, false);
    end
end
set_param([mdl '/YSIM'], 'SampleTime', sprintf('%.10g', P.Ts));

% ---- 검증 창 선택: test 분할에서 가장 긴 zigzag / turn / spin 각각 1개 ----
want = {'zigzag','turn_ccw','spin_cw','forward_full'};
pick = zeros(1,numel(want));
for i = 1:numel(want)
    best = 0;
    for ir = 1:numel(runs)
        R = runs(ir).R;
        if ~strcmp(R.split,'test') || ~strcmp(R.type,want{i}), continue, end
        if R.dur > best, best = R.dur; pick(i) = ir; end
    end
end
pick = pick(pick>0);

ids = {'D','F3'};
fprintf('\n=== Simulink vs MATLAB(tug_sim) 수치 일치 ===\n');
fprintf('%-4s %-14s %5s | %11s %11s %11s %11s %11s %11s\n', ...
    'mdl','기동','N', 'max|du|','max|dv|','max|dr|','max|dx|','max|dy|','max|dpsi|');
fprintf('%s\n', repmat('-',1,112));

MX = zeros(numel(ids)*numel(pick), 6);  row = 0;
for k = 1:numel(ids)
    TUG1_P  = MDL.(ids{k}).p;                                   %#ok<NASGU>
    for s = 1:numel(pick)
        R  = runs(pick(s)).R;
        sg = tug_segs(R.act, round(3.0/P.Ts));
        [~, ib] = max(sg(:,2)-sg(:,1));  a = sg(ib,1); b = sg(ib,2);
        tau = R.tau(a:b,:);
        L   = size(tau,1);
        t   = (0:L-1)'*P.Ts;

        x0  = [R.u(a), R.v(a), R.r(a), 0, 0, 0];
        TUG1_X0 = x0(:);                                        %#ok<NASGU>
        TAU_TS  = timeseries(tau, t);                           %#ok<NASGU>

        Ym = tug_sim(MDL.(ids{k}).Th, tau, P.Ts, x0, P.la);     % MATLAB 기준

        so = sim(mdl, 'StopTime', sprintf('%.10g',(L-1)*P.Ts));
        Ys = so.get('YSIM');
        if isa(Ys,'timeseries'), Ys = Ys.Data; end
        % ★ To Workspace(Array) 는 6x1 신호를 [6 1 N] 로 쌓는다 -> N x 6 으로 되돌린다
        if ndims(Ys) == 3, Ys = permute(squeeze(Ys), [2 1]); end
        if size(Ys,2) ~= 6 && size(Ys,1) == 6, Ys = Ys.'; end
        n  = min(size(Ys,1), L);

        dd = max(abs(Ys(1:n,:) - Ym(1:n,:)), [], 1);
        row = row + 1;  MX(row,:) = dd;
        fprintf('%-4s %-14s %5d | %11.3e %11.3e %11.3e %11.3e %11.3e %11.3e\n', ...
            ids{k}, strrep(R.type,'_','\_'), n, dd);
    end
end
fprintf('%s\n', repmat('-',1,112));
fprintf('전체 최대 편차: %s\n', mat2str(max(MX,[],1), 4));
if max(MX(:)) < 1e-6
    fprintf('★ 판정: 일치 (허용 1e-6). Simulink 모델을 RL 환경으로 그대로 써도 된다.\n');
else
    fprintf('⚠ 판정: 불일치. From Workspace 보간/솔버 설정을 확인할 것.\n');
end

save('..\out\tug1_slxchk.mat','MX','ids','want','-v7.3');
