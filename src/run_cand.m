%RUN_CAND  후보 모델을 '롤아웃 궤적'으로 선택한다 (1-step/적분 설명력이 아니라)
%
%  사용자 수락기준 = u,v,r + x,y,psi 가 실제와 맞는가. 따라서 선택기준도 그것이다.

P = tug_params();
if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;

B23 = {'m11','m22','m33','m23','Xu','Xuu','Xvv','Xrr','X0', ...
       'Yv','Yvv','Yr','Yrr','Yvr','Y0','Nr','Nrr','Nv','Nvv','Nuv','Nvr','Nur','N0'};

% 물리 하한: 부가질량은 양수 -> m11,m22 >= m ,  m33 >= Iz 하한

C = {};
mk = @(id,desc,names,mode,o) struct('id',id,'desc',desc,'names',{{names}},'mode',mode,'o',o);

C{end+1} = mk('A','미분형 23항 (현행)',              B23,'d', struct());
C{end+1} = mk('B','적분형 Twin=0.3 23항',            B23,'i', struct('Twin',0.3,'stride',0.1));
C{end+1} = mk('C','적분형 Twin=1.0 23항',            B23,'i', struct('Twin',1.0,'stride',0.2));
C{end+1} = mk('D','적분형 0.3 + 물리제약',           B23,'i', struct('Twin',0.3,'stride',0.1,'phys',1));

E1 = setdiff(B23, {'Yr','Yrr'}, 'stable');
C{end+1} = mk('E','D - {Yr,Yrr} (공선성 흡수항 제거)', E1,'i', struct('Twin',0.3,'stride',0.1,'phys',1));

F1 = [setdiff(B23, {'m23','Nur'}, 'stable'), {'mxg'}];
C{end+1} = mk('F','D + mxg (m23=Nur 통합)',          F1,'i', struct('Twin',0.3,'stride',0.1,'phys',1));

G1 = [B23, {'Ey1','Ey2','Ey3'}];
C{end+1} = mk('G','D + 바우 효율저하 Ey1..3',        G1,'i', struct('Twin',0.3,'stride',0.1,'phys',1));

H1 = [setdiff(B23, {'Yr','Yrr','m23','Nur'}, 'stable'), {'mxg','Ey1','Ey2','Ey3','dla'}];
C{end+1} = mk('H','E + mxg + Ey + dla',              H1,'i', struct('Twin',0.3,'stride',0.1,'phys',1));

eo = struct('minseg_s',3.0,'horiz_s',5.0);
RES = struct([]);
fprintf('%-3s %-34s | %-28s | %-28s\n','id','설명','train  zeta / ATE[m]','val    zeta / ATE[m]');
fprintf('%s\n', repmat('-',1,100));
for k = 1:numel(C)
    c = C{k};  nmk = c.names{1};  Np = numel(nmk);
    o = c.o;
    if isfield(o,'phys') && o.phys
        lb = -inf(Np,1);  ub = inf(Np,1);
        lb(strcmp(nmk,'m11')) = P.m;        % 17.86
        lb(strcmp(nmk,'m22')) = P.m;
        lb(strcmp(nmk,'m33')) = P.Iz_lo;    % 1.78
        o.lb = lb;  o.ub = ub;
    end
    if strcmp(c.mode,'d')
        th = tug_fit(runs, nmk, P, o);
    else
        th = tug_fit_int(runs, nmk, P, o);
    end
    Th = tug_theta(nmk, th);
    Et = tug_eval(Th, runs, P, setfield(eo,'split','train'));    %#ok<SFLD>
    Ev = tug_eval(Th, runs, P, setfield(eo,'split','val'));      %#ok<SFLD>
    RES(k).id = c.id;  RES(k).desc = c.desc;  RES(k).names = {nmk};
    RES(k).th = th;    RES(k).Th = Th;  RES(k).Et = Et;  RES(k).Ev = Ev;
    fprintf('%-3s %-34s | %8.4f / %8.3f          | %8.4f / %8.3f\n', ...
        c.id, c.desc, Et.zeta, Et.ate, Ev.zeta, Ev.ate);
end
fprintf('\n');
fprintf('%-3s   m11    m22    m33   m23/mxg |  rmse_u  rmse_v  rmse_r  rmse_x  rmse_y rmse_psi (val)\n','id');
for k=1:numel(RES)
    T = RES(k).Th;
    fprintf('%-3s %6.2f %6.2f %6.2f %8.2f | %7.4f %7.4f %7.4f %7.3f %7.3f %7.4f\n', ...
        RES(k).id, T.m11, T.m22, T.m33, T.m23, RES(k).Ev.rmse);
end
