function Th = tug_theta(names, th)
%TUG_THETA  파라미터 벡터 -> 이름 붙은 구조체 (없는 항은 0)
%
%  Th = tug_theta(names, th)
%
%  시뮬레이션 / Simulink 내보내기가 공통으로 쓰는 정규형.
%  m11/m22/m33 은 0 이면 안 되므로 호출측에서 반드시 포함시킬 것.
%
%  mxg 를 쓰면 m23 과 Nur 은 쓰지 않는다 (같은 물리량 m*xg 이다).

F = {'m11','m22','m33','m23','mxg', ...
     'Xu','Xuu','Xvv','Xrr','X0', ...
     'Yv','Yvv','Yr','Yrr','Yvr','Y0', ...
     'Nr','Nrr','Nv','Nvv','Nuv','Nvr','Nur','N0', ...
     'Ey1','Ey2','Ey3','Ex1','Ex2','dla'};
Th = struct();
for i = 1:numel(F), Th.(F{i}) = 0; end
for j = 1:numel(names)
    if ~isfield(Th, names{j}), error('미등록 항: %s', names{j}); end
    Th.(names{j}) = th(j);
end
% m23 과 mxg 는 같은 자리(M(2,3))를 쓴다. 둘 중 하나만 비0 이어야 한다.
Th.m23 = Th.m23 + Th.mxg;
end
