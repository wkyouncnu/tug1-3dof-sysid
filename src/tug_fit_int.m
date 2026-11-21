function [th, F] = tug_fit_int(runs, names, P, opt)
%TUG_FIT_INT  적분형 설계행렬로 3-DOF 계수 식별 (미분 불필요)
%
%  [th, F] = tug_fit_int(runs, names, P, opt)
%
%  opt.lambda (0)        Ridge
%  opt.irls   (2)        방정식별 가중 재추정
%  opt.split  ('train')
%  opt.Twin   (1.0)      적분창 [s]
%  opt.stride (0.2)      창 이동 [s]
%  opt.lb / opt.ub       (선택) 물리 부등식 제약 -> lsqlin 사용
%
%  tug_fit 과 완전히 같은 가중/정규화 절차를 쓰되 설계행렬만 적분형이다.
%  따라서 두 결과의 차이는 '수치미분을 썼는가' 하나에서만 온다.

if nargin < 4, opt = struct; end
if ~isfield(opt,'lambda'), opt.lambda = 0;       end
if ~isfield(opt,'irls'),   opt.irls   = 2;       end
if ~isfield(opt,'split'),  opt.split  = 'train'; end
if ~isfield(opt,'Twin'),   opt.Twin   = 1.0;     end
if ~isfield(opt,'stride'), opt.stride = 0.2;     end
if ~isfield(opt,'lb'),     opt.lb = [];          end
if ~isfield(opt,'ub'),     opt.ub = [];          end

[A, b, info] = tug_design_int(runs, names, P, opt);
N  = info.nwin;
Np = numel(names);

cs = vecnorm(A, 2, 1).';  cs(cs==0) = 1;
An = A ./ cs.';

use_con = ~isempty(opt.lb) || ~isempty(opt.ub);
lbn = []; ubn = [];
if use_con
    lbn = opt.lb(:) .* cs;   ubn = opt.ub(:) .* cs;   % 정규화 공간으로 환산
    o_ls = optimoptions('lsqlin','Display','off','Algorithm','interior-point', ...
                        'MaxIterations',400);
end

w = 1 ./ max(rms_(reshape(b,N,3)), eps);
thn = zeros(Np,1);
for it = 0:opt.irls
    W  = repelem(w(:), N);
    Aw = An .* W;  bw = b .* W;
    if use_con
        if opt.lambda > 0
            G  = Aw.'*Aw;  rg = sqrt(opt.lambda*trace(G)/Np);
            Aw = [Aw ; rg*eye(Np)];  bw = [bw ; zeros(Np,1)];   %#ok<AGROW>
        end
        thn = lsqlin(Aw, bw, [], [], [], [], lbn, ubn, thn, o_ls);
    else
        G = Aw.'*Aw;
        if opt.lambda > 0, G = G + opt.lambda*trace(G)/Np*eye(Np); end
        thn = G \ (Aw.'*bw);
    end
    res = reshape(An*thn - b, N, 3);
    w   = 1 ./ max(rms_(res), eps);
end
th = thn ./ cs;

F = struct();
F.names   = {names};
F.N       = N;
F.info    = info;
F.res_rms = rms_(res);
F.b_rms   = rms_(reshape(b,N,3));
F.fit_pct = 100*(1 - F.res_rms ./ F.b_rms);
F.cond    = cond(An.'*An);
F.w       = w;
end

function y = rms_(X)
y = sqrt(mean(X.^2, 1));
end
