function [A, b, info] = tug_design_int(runs, names, P, opt)
%TUG_DESIGN_INT  ★ 적분형(integral form) 설계행렬 — 수치미분을 쓰지 않는다
%
%  [A, b, info] = tug_design_int(runs, names, P, opt)
%
%  opt.split  ('train')
%  opt.Twin   (1.0)  적분창 길이 [s]
%  opt.stride (0.2)  창 이동 간격 [s]
%
%  ---------------------------------------------------------------
%  왜 적분형인가
%  ---------------------------------------------------------------
%  미분형  M*nu_dot + (C+D)*nu = tau  를 쓰면 nu_dot 이 '설명변수'로
%  들어간다. nu_dot 은 수치미분 결과라 잡음을 품고 있고, 설명변수에
%  섞인 잡음은 계수를 0 쪽으로 끌어내린다(errors-in-variables 감쇠편향).
%  실제로 SG 창을 7->71 샘플로 늘리자 m22 가 3.4 -> 11.0 으로 단조증가하고
%  수렴하지 않았다. 즉 m22/m33/m23 추정치는 전부 이 편향의 산물이었다.
%
%  창 [t1, t2] 에서 운동방정식을 그대로 적분하면
%
%     M*(nu(t2) - nu(t1)) + int_{t1}^{t2} (C(nu)nu + D(nu)nu) dt
%                         = int_{t1}^{t2} tau dt
%
%  좌변 첫 항은 '속도의 끝점 차이'라 미분이 필요 없고, 나머지는 전부
%  속도의 적분이라 오히려 잡음이 평균화된다. theta 에 대한 선형성은
%  그대로 유지되므로 최소자승이 여전히 닫힌형으로 풀린다.
%  (Fossen 2nd ed. 의 integral/modulating-function 식별과 같은 계열)
%
%  ---------------------------------------------------------------
%  구현
%  ---------------------------------------------------------------
%  각 항은 (A) 속도/추력만으로 된 '상태부' 와
%          (B) nu_dot 에 계수 1 로 붙는 '관성부' 로 분해된다.
%  상태부는 trapz 적분, 관성부는 끝점 차이로 정확히 계산한다.

if nargin < 4, opt = struct; end
if ~isfield(opt,'split'),  opt.split  = 'train'; end
if ~isfield(opt,'Twin'),   opt.Twin   = 1.0;     end
if ~isfield(opt,'stride'), opt.stride = 0.2;     end

Ts = P.Ts;
L  = max(2, round(opt.Twin/Ts));
St = max(1, round(opt.stride/Ts));
Np = numel(names);

Ar = {};  br = {};  wr = {};
nwin = 0;

for ir = 1:numel(runs)
    R = runs(ir).R;
    if ~strcmp(opt.split,'all') && ~strcmp(R.split, opt.split), continue, end
    sg = tug_segs(R.act, L+1);
    for is = 1:size(sg,1)
        i0 = sg(is,1);  i1 = sg(is,2);
        u = R.u(i0:i1);  v = R.v(i0:i1);  r = R.r(i0:i1);
        ta = R.tau(i0:i1,:);
        n  = numel(u);

        % --- 샘플별 상태부 (3n x Np) 와 관성 지정 ---
        [Cs, DS] = local_cols(u, v, r, ta, names, P);

        % --- 누적적분 (사다리꼴) : cumsum 으로 O(n) ---
        %     I(k) = int_{1}^{k}  ->  창적분 = I(b) - I(a)
        Ic = local_cumtrapz(Cs, n, 3, Ts);        % (3n x Np) 누적
        Ib = local_cumtrapz(ta(:), n, 3, Ts);      % (3n x 1)  tau 누적

        a0 = (1:St:(n-L)).';
        if isempty(a0), continue, end
        a1 = a0 + L;

        for q = 1:numel(a0)
            ka = a0(q);  kb = a1(q);
            row = zeros(3, Np);
            for j = 1:Np
                % 상태부 창적분
                for e = 1:3
                    row(e,j) = Ic((e-1)*n+kb, j) - Ic((e-1)*n+ka, j);
                end
                % 관성부 끝점차이
                for s = 1:size(DS{j},1)
                    e  = DS{j}(s,1);   iq = DS{j}(s,2);
                    switch iq
                        case 1, dnu = u(kb)-u(ka);
                        case 2, dnu = v(kb)-v(ka);
                        case 3, dnu = r(kb)-r(ka);
                    end
                    row(e,j) = row(e,j) + dnu;
                end
            end
            rhs = [Ib(kb)       - Ib(ka) ;
                   Ib(n+kb)     - Ib(n+ka) ;
                   Ib(2*n+kb)   - Ib(2*n+ka)];
            nwin = nwin + 1;
            Ar{nwin} = row;  br{nwin} = rhs;                     %#ok<AGROW>
            wr{nwin} = [ir is];                                  %#ok<AGROW>
        end
    end
end
assert(nwin > 0, '적분창을 만들 수 없다 (분할 "%s")', opt.split);

% 블록 재배치: eq1 전체 -> eq2 전체 -> eq3 전체  (tug_fit 의 블록가중과 호환)
A = zeros(3*nwin, Np);  b = zeros(3*nwin, 1);
for e = 1:3
    for q = 1:nwin
        A((e-1)*nwin+q, :) = Ar{q}(e,:);
        b((e-1)*nwin+q)    = br{q}(e);
    end
end
info = struct('nwin', nwin, 'L', L, 'Twin', L*Ts, 'stride', St*Ts, ...
              'src', {vertcat(wr{:})});
end

% =====================================================================
function I = local_cumtrapz(X, n, nb, Ts)
% X: (nb*n x m) 을 블록별로 누적 사다리꼴 적분. I(1)=0.
m = size(X,2);
I = zeros(nb*n, m);
for e = 1:nb
    k = (e-1)*n + (1:n);
    Y = X(k,:);
    I(k,:) = [zeros(1,m); cumsum(0.5*(Y(1:end-1,:)+Y(2:end,:))*Ts, 1)];
end
end

% =====================================================================
function [Cs, DS] = local_cols(u, v, r, ta, names, P)
% Cs : (3n x Np) 상태부 (nu_dot 없음)
% DS : Np x 1 cell, 각 원소는 [eq, nu_index] 행렬 (nu_dot 계수 1 인 자리)
n  = numel(u);
z  = zeros(n,1);  o = ones(n,1);
la = P.la;
tx = ta(:,1);  ty = ta(:,2);  tn = ta(:,3);
td = tn - la*ty;
Np = numel(names);
Cs = zeros(3*n, Np);
DS = cell(Np,1);

for j = 1:Np
    D = zeros(0,2);
    switch names{j}
        % ---- 질량/부가질량 ----
        case 'm11', c = [ z ; u.*r ; -u.*v ];          D = [1 1];
        case 'm22', c = [ -v.*r ; z ; u.*v ];          D = [2 2];
        case 'm33', c = [ z ; z ; z ];                 D = [3 3];
        case 'm23', c = [ z ; z ; z ];                 D = [2 3; 3 2];
        case 'mxg', c = [ -(r.^2) ; z ; u.*r ];        D = [2 3; 3 2];
        % ---- surge 감쇠 ----
        case 'Xu' , c = [ u ; z ; z ];
        case 'Xuu', c = [ abs(u).*u ; z ; z ];
        case 'Xvv', c = [ abs(v).*v ; z ; z ];
        case 'Xrr', c = [ abs(r).*r ; z ; z ];
        case 'X0' , c = [ o ; z ; z ];
        % ---- sway 감쇠 ----
        case 'Yv' , c = [ z ; v ; z ];
        case 'Yvv', c = [ z ; abs(v).*v ; z ];
        case 'Yr' , c = [ z ; r ; z ];
        case 'Yrr', c = [ z ; abs(r).*r ; z ];
        case 'Yvr', c = [ z ; abs(v).*r ; z ];
        case 'Y0' , c = [ z ; o ; z ];
        % ---- yaw 감쇠 ----
        case 'Nr' , c = [ z ; z ; r ];
        case 'Nrr', c = [ z ; z ; abs(r).*r ];
        case 'Nv' , c = [ z ; z ; v ];
        case 'Nvv', c = [ z ; z ; abs(v).*v ];
        case 'Nuv', c = [ z ; z ; u.*v ];
        case 'Nvr', c = [ z ; z ; abs(v).*r ];
        case 'Nur', c = [ z ; z ; u.*r ];
        case 'N0' , c = [ z ; z ; o ];
        % ---- 추진기 유효추력 저하 ----
        case 'Ey1', c = [ z ; -abs(u).*ty ; -la*abs(u).*ty ];
        case 'Ey2', c = [ z ; -(u.^2).*ty ; -la*(u.^2).*ty ];
        case 'Ey3', c = [ z ; -abs(v).*ty ; -la*abs(v).*ty ];
        case 'Ex1', c = [ -abs(u).*tx ; z ; -abs(u).*td ];
        case 'Ex2', c = [ -(u.^2).*tx ; z ; -(u.^2).*td ];
        case 'dla', c = [ z ; z ; -ty ];
        otherwise, error('알 수 없는 항: %s', names{j});
    end
    Cs(:,j) = c;
    DS{j}   = D;
end
end
