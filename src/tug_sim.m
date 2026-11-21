function Y = tug_sim(Th, tau, Ts, x0, la)
%TUG_SIM  3-DOF 조종모델 완전 재귀 롤아웃 (RK4, 측정 피드백 없음)
%
%  Y = tug_sim(Th, tau, Ts, x0, la)
%
%  Th  : tug_theta() 구조체
%  tau : [N x 3] 각 스텝의 '명목' 작용력 [tau_x, tau_y, tau_N]  (ZOH)
%        = T200 벤치곡선으로 복원한 값. 속도 의존 효율저하는 여기서 적용한다.
%  Ts  : 스텝 [s]
%  x0  : [u v r x y psi] 초기상태
%  la  : 바우추진기 모멘트팔 (기본 0.5)
%
%  Y   : [N x 6]  = [u v r x y psi]   (Y(1,:) = x0)
%
%  ★ 측정값을 전혀 다시 넣지 않는다 (문헌 공통 규약: fully recursive).
%    따라서 궤적 오차는 모델 오차가 순수하게 누적된 결과다.
%
%  ★ 유효추력 모델 (tug_design 의 Ex*/Ey*/dla 와 정확히 같은 식)
%      eta_x = 1 + Ex1*|u| + Ex2*u^2            (선미 2기)
%      eta_y = 1 + Ey1*|u| + Ey2*u^2 + Ey3*|v|  (바우 레터럴)
%      td    = tau_N - la*tau_y                 (선미 차동 모멘트분)
%      tau_eff = [ eta_x*tau_x ;
%                  eta_y*tau_y ;
%                  eta_x*td + (la + dla)*eta_y*tau_y ]

if nargin < 5 || isempty(la), la = 0.500; end

N  = size(tau,1);
Y  = zeros(N,6);
s  = x0(:).';
Y(1,:) = s;

M = [Th.m11 0       0      ;
     0      Th.m22  Th.m23 ;
     0      Th.m23  Th.m33];
if abs(det(M)) < 1e-9
    Y = repmat(s, N, 1);  return
end
Mi = inv(M);                                    %#ok<MINV>  3x3, 반복 역산 회피

for k = 1:N-1
    t1 = tau(k,:);
    t2 = tau(min(k+1,N),:);
    tm = 0.5*(t1+t2);
    k1 = local_f(s,          t1, Th, Mi, la);
    k2 = local_f(s+Ts/2*k1,  tm, Th, Mi, la);
    k3 = local_f(s+Ts/2*k2,  tm, Th, Mi, la);
    k4 = local_f(s+Ts*k3,    t2, Th, Mi, la);
    s  = s + Ts/6*(k1 + 2*k2 + 2*k3 + k4);
    % 발산 방지 (식별 실패 후보를 조기 탈락시키되 NaN 전파는 막는다)
    if ~all(isfinite(s)) || max(abs(s(1:3))) > 50
        s = max(min(s, 1e4), -1e4);
        s(~isfinite(s)) = 0;
        Y(k+1:end,:) = repmat(s, N-k, 1);
        return
    end
    Y(k+1,:) = s;
end
end

% =====================================================================
function ds = local_f(s, tau, Th, Mi, la)
u = s(1); v = s(2); r = s(3); psi = s(6);
au = abs(u);

% ---- 유효추력 ----
ex = 1 + Th.Ex1*au + Th.Ex2*u*u;
ey = 1 + Th.Ey1*au + Th.Ey2*u*u + Th.Ey3*abs(v);
td = tau(3) - la*tau(2);
te = [ ex*tau(1) ;
       ey*tau(2) ;
       ex*td + (la + Th.dla)*ey*tau(2) ];

% ---- 코리올리/원심 (강체 + 부가질량, CG 오프셋 m23 = m*xg 포함) ----
c = [ -Th.m22*v*r - Th.m23*r*r        ;
       Th.m11*u*r                     ;
      (Th.m22-Th.m11)*u*v + Th.m23*u*r ];

% ---- 감쇠 ----
d = [ Th.Xu*u + Th.Xuu*au*u + Th.Xvv*abs(v)*v + Th.Xrr*abs(r)*r + Th.X0 ;
      Th.Yv*v + Th.Yvv*abs(v)*v + Th.Yr*r + Th.Yrr*abs(r)*r + Th.Yvr*abs(v)*r + Th.Y0 ;
      Th.Nr*r + Th.Nrr*abs(r)*r + Th.Nv*v + Th.Nvv*abs(v)*v + Th.Nuv*u*v ...
              + Th.Nvr*abs(v)*r + Th.Nur*u*r + Th.N0 ];

nud = Mi*(te - c - d);

ds = [ nud(1), nud(2), nud(3), ...
       u*cos(psi) - v*sin(psi), ...
       u*sin(psi) + v*cos(psi), ...
       r ];
end
