function [th, F] = tug_fit(runs, names, P, opt)
%TUG_FIT  적층 전역 가중최소자승 / Ridge 로 3-DOF 계수를 동시 식별
%
%  [th, F] = tug_fit(runs, names, P, opt)
%
%  opt.lambda (0)   : Ridge 계수 (열 정규화 공간에서)
%  opt.irls   (2)   : 방정식별 가중 재추정 횟수 (0 = tau RMS 로 한 번만)
%  opt.split  ('train') : 쓸 분할. 'all' 이면 전부
%
%  ★ 세 방정식을 한 번에 푼다. m11 은 surge 의 du 계수이면서 sway 의 u*r 계수,
%    yaw 의 -u*v 계수이므로 '방정식 간 공유 제약'이 걸린다. 이것이
%    추력 스케일 축퇴(CLAUDE.md §2.5.1)를 깨는 장치다.
%
%  ★ 방정식별 가중: tau_x(~70 N), tau_N(~37 Nm) 단위가 달라 그냥 쌓으면
%    surge 가 해를 지배한다. 잔차 RMS 의 역수로 블록 가중한다(= IRLS).

if nargin < 4, opt = struct; end
if ~isfield(opt,'lambda'), opt.lambda = 0;       end
if ~isfield(opt,'irls'),   opt.irls   = 2;       end
if ~isfield(opt,'split'),  opt.split  = 'train'; end

%% ---------- 1. 활성 샘플 수집 ----------
U={};V={};Rr={};DU={};DV={};DR={};TA={};
for i = 1:numel(runs)
    R = runs(i).R;
    if ~strcmp(opt.split,'all') && ~strcmp(R.split, opt.split), continue, end
    a = R.act;  if ~any(a), continue, end
    U{end+1}=R.u(a); V{end+1}=R.v(a); Rr{end+1}=R.r(a);          %#ok<AGROW>
    DU{end+1}=R.du(a); DV{end+1}=R.dv(a); DR{end+1}=R.dr(a);     %#ok<AGROW>
    TA{end+1}=R.tau(a,:);                                        %#ok<AGROW>
end
assert(~isempty(U), '분할 "%s" 에 샘플이 없다', opt.split);
d = struct('u',vertcat(U{:}),'v',vertcat(V{:}),'r',vertcat(Rr{:}), ...
           'du',vertcat(DU{:}),'dv',vertcat(DV{:}),'dr',vertcat(DR{:}), ...
           'tau',vertcat(TA{:}));
N = numel(d.u);

%% ---------- 2. 설계행렬 ----------
[A, b] = tug_design(d, names, P);
cs = vecnorm(A, 2, 1).';  cs(cs==0) = 1;        % 열 정규화 (Ridge 공정성)
An = A ./ cs.';

%% ---------- 3. 블록 가중 IRLS ----------
w  = 1 ./ max(rms_(reshape(b,N,3)), eps);        % 초기: tau RMS^-1
Np = numel(names);
for it = 0:opt.irls
    W  = repelem(w(:), N);
    Aw = An .* W;  bw = b .* W;
    G  = Aw.'*Aw;
    if opt.lambda > 0
        G = G + opt.lambda*trace(G)/Np*eye(Np);
    end
    thn = G \ (Aw.'*bw);
    res = reshape(An*thn - b, N, 3);
    w   = 1 ./ max(rms_(res), eps);
end
th = thn ./ cs;

%% ---------- 4. 진단 ----------
F = struct();
F.names  = {names};
F.N      = N;
F.res_rms = rms_(res);                                  % [eq1 eq2 eq3] N, N, Nm
F.b_rms   = rms_(reshape(b,N,3));
F.fit_pct = 100*(1 - F.res_rms ./ F.b_rms);             % 방정식별 설명력
F.w       = w;
F.cond    = cond(An.'*An);
% 공선성: 정규화 설계행렬의 VIF
Rc = corrcoef(An);
F.vif = diag(inv(Rc)).';
F.corr = Rc;
% 파라미터 표준오차 (잔차 등분산 가정, 가중 포함)
W  = repelem(w(:), N);  Aw = An .* W;
s2 = sum((reshape(An*thn-b,N,3).*w).^2) / (3*N - Np);
C  = inv(Aw.'*Aw) * mean(s2);
F.se = sqrt(abs(diag(C))).' ./ cs.';
F.tstat = abs(th.') ./ max(F.se, eps);
end

function y = rms_(X)
y = sqrt(mean(X.^2, 1));
end
