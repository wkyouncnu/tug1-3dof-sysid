function [xs, dxs] = sg_diff(x, dt, framelen, order)
%SG_DIFF  Savitzky-Golay 국소 다항식 평활 + 1차 미분 (경계 포함)
%
%  [xs, dxs] = sg_diff(x, dt, framelen, order)
%
%  문헌 공통 규약(HW_SYSID_LITERATURE.md): framelen=51, order=3 @ 50 Hz
%  (= 1.02 s 창. 조종 동역학의 시정수보다 훨씬 짧고 IMU/EKF 잡음은 지운다)
%
%  Signal Processing Toolbox 의 sgolay 에 의존하지 않도록 Vandermonde
%  유사역행렬로 직접 구현한다. 경계에서는 끝 창의 적합 다항식을 해당
%  오프셋에서 평가하므로 길이가 줄지 않는다.

if nargin < 3, framelen = 51; end
if nargin < 4, order    = 3;  end
assert(mod(framelen,2)==1, 'framelen 은 홀수여야 한다');
assert(order < framelen,   'order < framelen 이어야 한다');

x  = x(:);
Nn = numel(x);
if Nn < framelen       % 너무 짧은 구간은 창을 줄인다
    framelen = max(order+2 - mod(order,2), 2*floor((Nn-1)/2)+1);
    if framelen < order+2, xs = x; dxs = gradient(x, dt); return; end
end

m  = (framelen-1)/2;
tt = (-m:m)'*dt;
V  = tt.^(0:order);            % framelen x (order+1)
Q  = pinv(V);                  % (order+1) x framelen  (최소자승 계수)

xs  = zeros(Nn,1);
dxs = zeros(Nn,1);

% --- 내부: 창 중앙(t=0) 에서 평가 => Q 의 1,2 행이 곧 가중치 ---
w0 = Q(1,:);                   % 값
w1 = Q(2,:);                   % 1차 미분
for i = m+1 : Nn-m
    seg    = x(i-m : i+m);
    xs(i)  = w0*seg;
    dxs(i) = w1*seg;
end

% --- 좌측 경계: 첫 창의 다항식을 tt(i) 에서 평가 ---
C = Q*x(1:framelen);                       % 계수 [c0 c1 c2 ...]'
for i = 1:m
    p      = tt(i).^(0:order);
    dp     = [0, (1:order).*tt(i).^(0:order-1)];
    xs(i)  = p*C;
    dxs(i) = dp*C;
end

% --- 우측 경계: 마지막 창의 다항식 ---
C = Q*x(Nn-framelen+1:Nn);
for k = 1:m
    i      = Nn-m+k;                       % tt 인덱스 m+1+k
    p      = tt(m+1+k).^(0:order);
    dp     = [0, (1:order).*tt(m+1+k).^(0:order-1)];
    xs(i)  = p*C;
    dxs(i) = dp*C;
end
end
