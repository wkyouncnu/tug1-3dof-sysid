function MDL = tug1_model(outMat)
%TUG1_MODEL  식별된 Tug1 3-DOF 운동모델 파라미터를 Simulink 로 넘길 형태로 내보낸다.
%
%  MDL = tug1_model()            -> 구조체만 반환
%  MDL = tug1_model(outMat)      -> ..\out\tug1_model.mat 로도 저장
%
%  ---------------------------------------------------------------
%  왜 '벡터' 로 내보내는가
%  ---------------------------------------------------------------
%  Simulink MATLAB Function 블록에 구조체 필드를 하나씩 넘기면 코드생성 시
%  심볼 테이블 설정이 번거롭다. 고정 길이 벡터 p 를 Constant 블록 하나로
%  넣으면 (a) 코드생성 안전 (b) 모델 교체가 베이스워크스페이스 변수 하나
%  바꾸는 일이 된다.
%
%  p 순서 (23개) — tug1_dyn.m 과 반드시 동일해야 한다:
%    1  m11     2  m22     3  m33     4  m23
%    5  Xu      6  Xuu     7  Xvv     8  Xrr     9  X0
%   10  Yv     11  Yvv    12  Yr     13  Yrr    14  Yvr    15  Y0
%   16  Nr     17  Nrr    18  Nv     19  Nvv    20  Nuv    21  Nvr
%   22  Nur    23  N0
%
%  ★ 추력항이 단순한 이유
%  식별 배터리에서 바우효율 가설(Ey1..3, dla)은 기각되었다(G 열화 / H 발산).
%  따라서 ex = ey = 1, dla = 0 이고 tug_sim 의
%     e3 = ex*(tauN - la*tauY) + (la+dla)*ey*tauY  =  tauN
%  이 되어 tau = [tau_x; tau_y; tau_N] 이 그대로 들어간다. la 가 운동방정식에
%  남지 않는다 (추력배분에만 쓰인다).

if nargin < 1, outMat = ''; end

P  = tug_params();
Zf = load('..\out\tug1_final.mat');          % MD (D, F3), EE, NS
MD = Zf.MD;

ORD = {'m11','m22','m33','m23','Xu','Xuu','Xvv','Xrr','X0', ...
       'Yv','Yvv','Yr','Yrr','Yvr','Y0', ...
       'Nr','Nrr','Nv','Nvv','Nuv','Nvr','Nur','N0'};

MDL = struct();
MDL.order = {ORD};
MDL.Ts    = P.Ts;
MDL.la    = P.la;
MDL.d     = P.d;
MDL.T     = P.T;                             % 추력배분 [X;Y;N] = T*f
MDL.m_meas  = P.m;
MDL.Iz_box  = P.Iz_box;
MDL.built   = datestr(now, 'yyyy-mm-dd HH:MM:SS');  %#ok<DATST,TNOW>

for im = 1:numel(MD)
    Th = MD(im).Th;
    p  = zeros(numel(ORD),1);
    for j = 1:numel(ORD)
        val = Th.(ORD{j});
        if ~isfinite(val), val = 0; end      % 해당 구조에 없는 항은 0
        p(j) = val;
    end
    id = MD(im).id;
    MDL.(id) = struct('p', p, 'Th', Th, 'names', {{MD(im).nm}}, 'th', MD(im).th);
end

% 기본 납품본 = F3 (물리상한 m22 <= 3m. 장지평 외삽이 D 보다 낫다)
MDL.default = 'F3';
MDL.p       = MDL.F3.p;
MDL.x0      = zeros(6,1);                    % [u v r x y psi]

if ~isempty(outMat)
    save(outMat, 'MDL', '-v7.3');
    fprintf('저장: %s\n', outMat);
end

fprintf('\n=== tug1_model: 파라미터 벡터 ===\n');
fprintf('%-6s %12s %12s\n', 'term', 'D', 'F3');
for j = 1:numel(ORD)
    fprintf('%-6s %12.4f %12.4f\n', ORD{j}, MDL.D.p(j), MDL.F3.p(j));
end
fprintf('기본(default) = %s,  Ts = %.3f s,  la = %.3f m,  d = %.3f m\n', ...
    MDL.default, MDL.Ts, MDL.la, MDL.d);
end
