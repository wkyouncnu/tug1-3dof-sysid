function [th, O] = tug_fit_oe(th0, names, W, P, opt)
%TUG_FIT_OE  ★ 출력오차(output-error / rollout) 최적화
%
%  [th, O] = tug_fit_oe(th0, names, W, P, opt)
%
%  th0   : 초기값 (적분형 LS 해). 반드시 필요하다 — 비선형 최소자승이다.
%  W     : tug_windows 결과 (훈련 분할)
%  opt.wch   ([1 1 1 1 1 1])  채널 가중 (1/sd 에 추가로 곱한다)
%  opt.lb/ub (빈칸)           물리 부등식
%  opt.maxit (60)
%
%  ---------------------------------------------------------------
%  왜 필요한가
%  ---------------------------------------------------------------
%  선형 LS 는 '1-step 또는 창적분 설명력'을 최대화한다. 그런데 이 프로젝트의
%  수락기준은 '완전 재귀 롤아웃으로 u,v,r,x,y,psi 가 맞는가' 다. 두 기준은
%  실제로 어긋났다:
%    - 미분형 LS 는 1-step 적합이 가장 좋았는데 롤아웃은 발산했다 (zeta 425).
%    - 적분형 Twin 을 늘리면 설명력은 단조증가하는데 m11 이 17.7 -> 3.7 로 붕괴했다.
%  따라서 마지막 단계는 기준 그 자체를 직접 최소화해야 한다.
%
%  목적함수 = sum_w sum_k sum_ch [ (yhat - y)/sd_ch ]^2
%  즉 zeta 의 제곱 버전이다. lsqnonlin(trust-region-reflective) 로 푼다.
%  (경계가 있으면 TRR 이 그대로 받는다)

if nargin < 5, opt = struct; end
if ~isfield(opt,'wch'),   opt.wch   = ones(1,6); end
if ~isfield(opt,'lb'),    opt.lb    = [];        end
if ~isfield(opt,'ub'),    opt.ub    = [];        end
if ~isfield(opt,'maxit'), opt.maxit = 60;        end
if ~isfield(opt,'disp'),  opt.disp  = 'iter-detailed'; end

Np = numel(names);
th0 = th0(:);

% 스케일 정규화: 파라미터 크기가 10^0 ~ 10^2 로 섞여 있어 그대로 두면
% 유한차분 스텝이 작은 항에서 의미가 없어진다.
sc = max(abs(th0), 1e-3);
z0 = th0 ./ sc;

lb = []; ub = [];
if ~isempty(opt.lb), lb = opt.lb(:) ./ sc; end
if ~isempty(opt.ub), ub = opt.ub(:) ./ sc; end
if ~isempty(lb), z0 = max(z0, lb+1e-9); end
if ~isempty(ub), z0 = min(z0, ub-1e-9); end

wg = (opt.wch(:).' ./ max(W.sd, eps));          % [1x6]
nres = W.L * W.nW * 6;

f = @(z) local_res(z, sc, names, W, P, wg, nres);

o = optimoptions('lsqnonlin', ...
    'Display', opt.disp, ...
    'Algorithm','trust-region-reflective', ...
    'MaxIterations', opt.maxit, ...
    'MaxFunctionEvaluations', opt.maxit*(Np+2), ...
    'FiniteDifferenceType','forward', ...
    'FunctionTolerance', 1e-8, ...
    'StepTolerance', 1e-10, ...
    'SpecifyObjectiveGradient', false);

[z, resn, ~, exitflag, outp] = lsqnonlin(f, z0, lb, ub, o);
th = z .* sc;

r0 = f(z0);
O = struct();
O.names    = {names};
O.exitflag = exitflag;
O.iters    = outp.iterations;
O.nfev     = outp.funcCount;
O.J0       = sum(r0.^2);
O.J        = resn;
O.zeta0    = local_zeta(z0, sc, names, W, P);
O.zeta     = local_zeta(z,  sc, names, W, P);
O.nW       = W.nW;
O.L        = W.L;
end

% =====================================================================
function r = local_res(z, sc, names, W, P, wg, nres)
Th = tug_theta(names, z .* sc);
[U,V,Rr,X,Y,PS] = tug_sim_batch(Th, W.TX, W.TY, W.TN, W.Ts, W.x0, P.la);
E = cat(3, U - W.Z(:,:,1), V - W.Z(:,:,2), Rr - W.Z(:,:,3), ...
           X - W.Z(:,:,4), Y - W.Z(:,:,5), wrapToPi(PS - W.Z(:,:,6)));
for i = 1:6, E(:,:,i) = E(:,:,i) * wg(i); end
r = E(:) / sqrt(nres);
r(~isfinite(r)) = 1e3;
end

% =====================================================================
function [zt, rm] = local_zeta(z, sc, names, W, P)
Th = tug_theta(names, z .* sc);
[U,V,Rr,X,Y,PS] = tug_sim_batch(Th, W.TX, W.TY, W.TN, W.Ts, W.x0, P.la);
D = {U - W.Z(:,:,1), V - W.Z(:,:,2), Rr - W.Z(:,:,3), ...
     X - W.Z(:,:,4), Y - W.Z(:,:,5), wrapToPi(PS - W.Z(:,:,6))};
rm = zeros(1,6);
for i=1:6, d = D{i}(:);  d(~isfinite(d)) = 1e3;  rm(i) = sqrt(mean(d.^2)); end
zt = mean(rm ./ max(W.sd, eps));
end
