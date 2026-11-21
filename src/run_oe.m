%RUN_OE  구조 후보 x 출력오차(rollout) 최적화 배터리
%
%  2단: ① 적분형 제약 LS 로 초기값  ② 출력오차 최적화(2회 재시작)
%  선택기준 = val 롤아웃 zeta / ATE. test 분할은 건드리지 않는다.

P = tug_params();
if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;

B23 = {'m11','m22','m33','m23','Xu','Xuu','Xvv','Xrr','X0', ...
       'Yv','Yvv','Yr','Yrr','Yvr','Y0','Nr','Nrr','Nv','Nvv','Nuv','Nvr','Nur','N0'};
noM = @(s) setdiff(B23, s, 'stable');

K = {};
mk = @(id,desc,names,ub22) struct('id',id,'desc',desc,'names',{{names}},'ub22',ub22);
K{end+1} = mk('D' ,'23항 (m23+Nur 분리)',        B23,                                 inf);
K{end+1} = mk('F' ,'mxg 통합 (22항)',            [noM({'m23','Nur'}), {'mxg'}],        inf);
K{end+1} = mk('G' ,'23항 + 바우효율 Ey1..3',     [B23, {'Ey1','Ey2','Ey3'}],           inf);
K{end+1} = mk('H' ,'mxg + Ey + dla',             [noM({'m23','Nur'}), {'mxg','Ey1','Ey2','Ey3','dla'}], inf);
K{end+1} = mk('F3','mxg, m22<=3m (물리 상한)',   [noM({'m23','Nur'}), {'mxg'}],        3*P.m);
K{end+1} = mk('Fs','mxg - {Xvv,Xrr,Nvv} (간소)', [noM({'m23','Nur','Xvv','Xrr','Nvv'}), {'mxg'}], inf);

Wtr = tug_windows(runs, P, struct('split','train','horiz_s',5.0));
eo  = struct('minseg_s',3.0,'horiz_s',5.0);
Q   = struct([]);

fprintf('%-4s %-30s | %-18s | %-18s | %s\n','id','구조','train zeta/ATE','val zeta/ATE','m11 m22 m33');
fprintf('%s\n', repmat('-',1,104));
for k = 1:numel(K)
    c = K{k};  nm = c.names{1};  Np = numel(nm);
    lb = -inf(Np,1);  ub = inf(Np,1);
    lb(strcmp(nm,'m11')) = P.m;
    lb(strcmp(nm,'m22')) = P.m;   ub(strcmp(nm,'m22')) = c.ub22;
    lb(strcmp(nm,'m33')) = P.Iz_lo;
    % 효율항은 eta>0 유지를 위해 느슨한 경계
    for s = {'Ey1','Ey2','Ey3'}
        j = strcmp(nm, s{1});  if any(j), lb(j) = -0.8;  ub(j) = 0.8; end
    end

    th = tug_fit_int(runs, nm, P, struct('Twin',0.3,'stride',0.1,'lb',lb,'ub',ub));
    for rs = 1:2                                  % 재시작 2회
        th = tug_fit_oe(th, nm, Wtr, P, struct('lb',lb,'ub',ub,'maxit',200,'disp','off'));
    end
    Th = tug_theta(nm, th);
    Et = tug_eval(Th, runs, P, setfield(eo,'split','train'));   %#ok<SFLD>
    Ev = tug_eval(Th, runs, P, setfield(eo,'split','val'));     %#ok<SFLD>
    Q(k).id=c.id; Q(k).desc=c.desc; Q(k).names={nm}; Q(k).th=th; Q(k).Th=Th;
    Q(k).Et=Et; Q(k).Ev=Ev; Q(k).lb=lb; Q(k).ub=ub;
    fprintf('%-4s %-30s | %7.4f / %7.3f  | %7.4f / %7.3f  | %6.2f %7.2f %6.2f\n', ...
        c.id, c.desc, Et.zeta,Et.ate, Ev.zeta,Ev.ate, Th.m11,Th.m22,Th.m33);
end

fprintf('\n%-4s %8s %8s %8s %8s %8s %8s | %s\n','val','nrm_u','nrm_v','nrm_r','nrm_x','nrm_y','nrm_ps','rmse_x[m] rmse_ps[rad]');
for k=1:numel(Q)
    fprintf('%-4s %8.3f %8.3f %8.3f %8.3f %8.3f %8.3f | %8.3f %8.4f\n', ...
        Q(k).id, Q(k).Ev.nrmse, Q(k).Ev.rmse(4), Q(k).Ev.rmse(6));
end
save('..\out\tug1_oe.mat','Q','Wtr','-v7.3');
