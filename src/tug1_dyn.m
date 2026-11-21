function ds = tug1_dyn(s, tau, p)
%TUG1_DYN  Tug1 3-DOF 운동방정식 (Simulink MATLAB Function 블록 본체)
%#codegen
%
%  s   = [u; v; r; x; y; psi]      (바디 FRD / 월드 NED, Fossen 규약)
%  tau = [tau_x; tau_y; tau_N]     (바디 작용력/모멘트)
%  p   = 23x1 파라미터 (tug1_model.m 의 ORD 순서와 반드시 동일)
%  ds  = [du; dv; dr; dx; dy; dpsi]
%
%  ★ tug_sim / tug_sim_batch 의 loc_f 와 수식이 동일하다.
%    바우효율 가설이 기각되어 ex = ey = 1, dla = 0 이므로
%      e3 = ex*(tauN - la*tauY) + (la+dla)*ey*tauY = tauN
%    즉 la 는 운동방정식에 나타나지 않는다 (추력배분 전단에만 쓰인다).

m11=p(1);  m22=p(2);  m33=p(3);  m23=p(4);
Xu =p(5);  Xuu=p(6);  Xvv=p(7);  Xrr=p(8);  X0 =p(9);
Yv =p(10); Yvv=p(11); Yr =p(12); Yrr=p(13); Yvr=p(14); Y0=p(15);
Nr =p(16); Nrr=p(17); Nv =p(18); Nvv=p(19); Nuv=p(20); Nvr=p(21);
Nur=p(22); N0 =p(23);

u = s(1);  v = s(2);  r = s(3);  psi = s(6);
au = abs(u);  av = abs(v);  ar = abs(r);

% 관성/코리올리 + 감쇠를 우변으로 넘긴다
e1 = tau(1) - ( -m22*v*r - m23*r*r ) ...
            - ( Xu*u + Xuu*au*u + Xvv*av*v + Xrr*ar*r + X0 );
e2 = tau(2) - (  m11*u*r ) ...
            - ( Yv*v + Yvv*av*v + Yr*r + Yrr*ar*r + Yvr*av*r + Y0 );
e3 = tau(3) - ( (m22-m11)*u*v + m23*u*r ) ...
            - ( Nr*r + Nrr*ar*r + Nv*v + Nvv*av*v + Nuv*u*v + Nvr*av*r ...
                + Nur*u*r + N0 );

M = [m11 0 0; 0 m22 m23; 0 m23 m33];
a = M \ [e1; e2; e3];

ds = [ a(1); ...
       a(2); ...
       a(3); ...
       u*cos(psi) - v*sin(psi); ...
       u*sin(psi) + v*cos(psi); ...
       r ];
end
