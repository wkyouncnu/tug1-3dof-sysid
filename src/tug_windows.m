function W = tug_windows(runs, P, opt)
%TUG_WINDOWS  롤아웃 최적화/평가용 고정길이 창 집합을 만든다 (직사각 배열)
%
%  W = tug_windows(runs, P, opt)
%    opt.split    ('train')
%    opt.horiz_s  (5.0)   창 길이 [s]
%    opt.stride_s ([])    창 시작 간격 [s]. 비우면 창 길이 (겹침 없음)
%    opt.minseg_s (3.0)
%
%  반환
%    W.TX,TY,TN : [L x nW] 추력
%    W.Z        : [L x nW x 6] 측정 [u v r x y psi]
%    W.x0       : [nW x 6]
%    W.sd       : [1 x 6] 채널별 측정 표준편차 (가중치용)
%    W.src      : [nW x 3] (run index, seg index, start sample)
%
%  ★ 위치/방위는 창 시작을 원점으로 두되, 방위를 0 으로 되돌리므로
%    변위도 -psi0 만큼 같이 회전시켜야 한다. 안 하면 좌표계 회전을
%    모델오차로 재게 된다 (0.14 m -> 4.06 m).

if nargin < 3, opt = struct; end
if ~isfield(opt,'split'),    opt.split    = 'train'; end
if ~isfield(opt,'horiz_s'),  opt.horiz_s  = 5.0;     end
if ~isfield(opt,'stride_s'), opt.stride_s = [];      end
if ~isfield(opt,'minseg_s'), opt.minseg_s = 3.0;     end

Ts = P.Ts;
L  = round(opt.horiz_s/Ts);
if isempty(opt.stride_s), St = L; else, St = max(1, round(opt.stride_s/Ts)); end

TX={}; TY={}; TN={}; ZZ={}; X0={}; SRC={};
nw = 0;
for ir = 1:numel(runs)
    R = runs(ir).R;
    if ~strcmp(opt.split,'all') && ~strcmp(R.split, opt.split), continue, end
    sg = tug_segs(R.act, round(opt.minseg_s/Ts));
    for is = 1:size(sg,1)
        i0 = sg(is,1);  i1 = sg(is,2);
        for a = i0:St:(i1-L+1)
            b = a + L - 1;
            Zm = [R.u(a:b), R.v(a:b), R.r(a:b), R.x(a:b), R.y(a:b), R.psi(a:b)];
            p0 = Zm(1,6);
            dX = Zm(:,4) - Zm(1,4);
            dY = Zm(:,5) - Zm(1,5);
            Zm(:,4) =  cos(p0)*dX + sin(p0)*dY;
            Zm(:,5) = -sin(p0)*dX + cos(p0)*dY;
            Zm(:,6) = Zm(:,6) - p0;
            nw = nw + 1;
            TX{nw} = R.tau(a:b,1);  TY{nw} = R.tau(a:b,2);  TN{nw} = R.tau(a:b,3); %#ok<AGROW>
            ZZ{nw} = Zm;                                                           %#ok<AGROW>
            X0{nw} = [Zm(1,1:3), 0, 0, 0];                                         %#ok<AGROW>
            SRC{nw} = [ir is a];                                                   %#ok<AGROW>
        end
    end
end
assert(nw > 0, '창을 만들 수 없다 (분할 "%s", 길이 %.1f s)', opt.split, opt.horiz_s);

W = struct();
W.L = L;  W.nW = nw;  W.Ts = Ts;  W.horiz_s = L*Ts;  W.split = opt.split;
W.TX = cell2mat(TX);  W.TY = cell2mat(TY);  W.TN = cell2mat(TN);
W.Z  = reshape(cell2mat(ZZ), L, 6, nw);        % [L x 6 x nW]
W.Z  = permute(W.Z, [1 3 2]);                  % [L x nW x 6]
W.x0 = cell2mat(X0.');
W.src= cell2mat(SRC.');
sd = zeros(1,6);
for i=1:6, z = W.Z(:,:,i);  sd(i) = std(z(:)); end
W.sd = sd;
end
