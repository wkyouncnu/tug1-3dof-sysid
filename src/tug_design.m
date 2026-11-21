function [A, b] = tug_design(d, names, P)
%TUG_DESIGN  3-DOF Fossen 조종모델의 선형 설계행렬 (3개 방정식 동시 적층)
%
%  [A, b] = tug_design(d, names)
%
%  d     : 필드 u,v,r,du,dv,dr,tau  (N x 1 / tau 는 N x 3)
%  names : 파라미터 이름 cell. 아래 사전(dictionary) 중에서 고른다.
%
%  모델 (FRD 바디, M*nu_dot + C(nu)*nu + D(nu)*nu = tau)
%     M = [m11  0    0  ;        C(nu)*nu = [ -m22*v*r      ;
%          0   m22  m23;                       m11*u*r      ;
%          0   m23  m33]                      (m22-m11)*u*v ]
%
%  적층 형태:   A(theta) = b,   b = [tau_x ; tau_y ; tau_N]
%    eq1:  m11*du - m22*(v r) + Xu*u + Xuu*|u|u + Xvv*|v|v + X0           = tau_x
%    eq2:  m22*dv + m23*dr + m11*(u r) + Yv*v + Yvv*|v|v + Yr*r + Yrr*|r|r + Y0 = tau_y
%    eq3:  m23*dv + m33*dr + (m22-m11)*(u v) + Nr*r + Nrr*|r|r + Nv*v + Nvv*|v|v + Nuv*(u v) + N0 = tau_N
%
%  ★ m11, m22 가 세 방정식에 '공유'되는 것이 핵심이다.
%     m11 은 eq1 의 du 계수이면서 동시에 eq2 의 u*r 계수, eq3 의 -u*v 계수다.
%     따라서 전역 스케일 축퇴가 깨지고, 식별된 m11 을 실측질량 17.86 kg 과
%     비교하는 것만으로 추력 스케일(k_T)을 독립 검증할 수 있다 (CLAUDE.md §2.5.1).

u = d.u(:);  v = d.v(:);  r = d.r(:);
du = d.du(:); dv = d.dv(:); dr = d.dr(:);
N = numel(u);  z = zeros(N,1);  o = ones(N,1);

if nargin < 3 || isempty(P), la = 0.500; else, la = P.la; end
tx = d.tau(:,1);  ty = d.tau(:,2);  tn = d.tau(:,3);
td = tn - la*ty;              % 선미 차동추력이 기여하는 yaw 모멘트 성분

Np = numel(names);
A  = zeros(3*N, Np);
for j = 1:Np
    switch names{j}
        % ---- 질량/부가질량 (방정식 간 공유) ----
        case 'm11', c = [ du    ;  u.*r ; -u.*v ];
        case 'm22', c = [-v.*r  ;  dv   ;  u.*v ];
        case 'm33', c = [ z     ;  z    ;  dr   ];
        case 'm23', c = [ z     ;  dr   ;  dv   ];
        % ---- surge 감쇠 ----
        case 'Xu' , c = [ u          ; z ; z ];
        case 'Xuu', c = [ abs(u).*u  ; z ; z ];
        case 'Xvv', c = [ abs(v).*v  ; z ; z ];
        case 'Xrr', c = [ abs(r).*r  ; z ; z ];
        case 'X0' , c = [ o          ; z ; z ];
        % ---- sway 감쇠 ----
        case 'Yv' , c = [ z ; v          ; z ];
        case 'Yvv', c = [ z ; abs(v).*v  ; z ];
        case 'Yr' , c = [ z ; r          ; z ];
        case 'Yrr', c = [ z ; abs(r).*r  ; z ];
        case 'Yvr', c = [ z ; abs(v).*r  ; z ];
        case 'Y0' , c = [ z ; o          ; z ];
        % ---- yaw 감쇠 ----
        case 'Nr' , c = [ z ; z ; r          ];
        case 'Nrr', c = [ z ; z ; abs(r).*r  ];
        case 'Nv' , c = [ z ; z ; v          ];
        case 'Nvv', c = [ z ; z ; abs(v).*v  ];
        case 'Nuv', c = [ z ; z ; u.*v       ];
        case 'Nvr', c = [ z ; z ; abs(v).*r  ];
        case 'Nur', c = [ z ; z ; u.*r       ];
        case 'N0' , c = [ z ; z ; o          ];
        % ---- ★ 추진기 유효추력 저하 (속도 의존) ----
        %  바우 레터럴 추진기: tau_y_eff = (1 + Ey1*|u| + Ey2*u^2)*tau_y
        %  좌변으로 옮기면 -Ey*|u|*tau_y 가 regressor 가 된다.
        %  ★ eq2 와 eq3 에 동일 계수가 la 배로 함께 들어간다 = 교차 제약
        case 'Ey1', c = [ z ; -abs(u).*ty    ; -la*abs(u).*ty    ];
        case 'Ey2', c = [ z ; -(u.^2).*ty    ; -la*(u.^2).*ty    ];
        case 'Ey3', c = [ z ; -abs(v).*ty    ; -la*abs(v).*ty    ];
        %  선미 추진기: tau_x_eff = (1 + Ex1*|u|)*tau_x, 차동분도 같은 비율
        case 'Ex1', c = [ -abs(u).*tx ; z    ; -abs(u).*td       ];
        case 'Ex2', c = [ -(u.^2).*tx ; z    ; -(u.^2).*td       ];
        % ---- ★ CoG 오프셋 (상태 원점 != 질량중심), CG = (xg, 0) ----
        %  eq1: -m*xg*r^2   eq2: +m*xg*dr   eq3: +m*xg*(dv + u*r)
        %  m23 = m*xg 와 Nur = m*xg 가 같은 양이어야 한다 -> mxg 하나로 묶는다
        case 'mxg', c = [ -(r.^2) ; dr ; dv + u.*r ];
        % ---- ★ 바우 모멘트팔 보정 (상태 원점 기준 la_true = la + dla) ----
        case 'dla', c = [ z ; z ; -ty ];
        otherwise, error('알 수 없는 항: %s', names{j});
    end
    A(:,j) = c;
end
b = [d.tau(:,1); d.tau(:,2); d.tau(:,3)];
end
