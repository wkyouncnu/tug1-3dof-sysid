function [U,V,Rr,X,Y,PS] = tug_sim_batch(Th, TX, TY, TN, Ts, x0, la)
%TUG_SIM_BATCH  여러 창을 동시에 롤아웃 (RK4, 벡터화). tug_sim 과 수식 동일.
%
%  TX,TY,TN : [L x W]  각 창의 추력 시계열 (ZOH, 창마다 열 하나)
%  x0       : [W x 6]  창별 초기상태 [u v r x y psi]
%  반환      : 각 [L x W]
%
%  ★ 출력오차(rollout) 최적화용. 창 하나씩 돌리면 목적함수 1회가 수십만 번의
%    함수호출이 되어 최적화가 불가능하다. 창 축을 벡터화하면 스텝 수만 남는다.

if nargin < 7 || isempty(la), la = 0.500; end
[L, W] = size(TX);

M = [Th.m11 0 0; 0 Th.m22 Th.m23; 0 Th.m23 Th.m33];
U = zeros(L,W); V = U; Rr = U; X = U; Y = U; PS = U;
if abs(det(M)) < 1e-9 || ~all(isfinite(M(:)))
    U(:)=x0(1,1); return
end
Mi = inv(M);                                                     %#ok<MINV>

u = x0(:,1).'; v = x0(:,2).'; r = x0(:,3).';
x = x0(:,4).'; y = x0(:,5).'; p = x0(:,6).';
U(1,:)=u; V(1,:)=v; Rr(1,:)=r; X(1,:)=x; Y(1,:)=y; PS(1,:)=p;

for k = 1:L-1
    k2 = min(k+1, L);
    t1 = [TX(k,:); TY(k,:); TN(k,:)];
    t2 = [TX(k2,:); TY(k2,:); TN(k2,:)];
    tm = 0.5*(t1+t2);
    s  = [u;v;r;x;y;p];
    d1 = loc_f(s,          t1, Th, Mi, la);
    d2 = loc_f(s+Ts/2*d1,  tm, Th, Mi, la);
    d3 = loc_f(s+Ts/2*d2,  tm, Th, Mi, la);
    d4 = loc_f(s+Ts*d3,    t2, Th, Mi, la);
    s  = s + Ts/6*(d1 + 2*d2 + 2*d3 + d4);
    bad = ~all(isfinite(s),1) | max(abs(s(1:3,:)),[],1) > 50;
    if any(bad)
        s(:,bad) = max(min(s(:,bad), 1e3), -1e3);
        s(~isfinite(s)) = 0;
    end
    u=s(1,:); v=s(2,:); r=s(3,:); x=s(4,:); y=s(5,:); p=s(6,:);
    U(k+1,:)=u; V(k+1,:)=v; Rr(k+1,:)=r; X(k+1,:)=x; Y(k+1,:)=y; PS(k+1,:)=p;
end
end

% =====================================================================
function ds = loc_f(s, tau, Th, Mi, la)
u=s(1,:); v=s(2,:); r=s(3,:); p=s(6,:);
au=abs(u); av=abs(v); ar=abs(r);

ex = 1 + Th.Ex1*au + Th.Ex2*u.*u;
ey = 1 + Th.Ey1*au + Th.Ey2*u.*u + Th.Ey3*av;
td = tau(3,:) - la*tau(2,:);
e1 = ex.*tau(1,:);
e2 = ey.*tau(2,:);
e3 = ex.*td + (la + Th.dla)*ey.*tau(2,:);

e1 = e1 - ( -Th.m22*v.*r - Th.m23*r.*r );
e2 = e2 - (  Th.m11*u.*r );
e3 = e3 - ( (Th.m22-Th.m11)*u.*v + Th.m23*u.*r );

e1 = e1 - ( Th.Xu*u + Th.Xuu*au.*u + Th.Xvv*av.*v + Th.Xrr*ar.*r + Th.X0 );
e2 = e2 - ( Th.Yv*v + Th.Yvv*av.*v + Th.Yr*r + Th.Yrr*ar.*r + Th.Yvr*av.*r + Th.Y0 );
e3 = e3 - ( Th.Nr*r + Th.Nrr*ar.*r + Th.Nv*v + Th.Nvv*av.*v + Th.Nuv*u.*v ...
            + Th.Nvr*av.*r + Th.Nur*u.*r + Th.N0 );

ds = [ Mi(1,1)*e1 + Mi(1,2)*e2 + Mi(1,3)*e3 ;
       Mi(2,1)*e1 + Mi(2,2)*e2 + Mi(2,3)*e3 ;
       Mi(3,1)*e1 + Mi(3,2)*e2 + Mi(3,3)*e3 ;
       u.*cos(p) - v.*sin(p) ;
       u.*sin(p) + v.*cos(p) ;
       r ];
end
