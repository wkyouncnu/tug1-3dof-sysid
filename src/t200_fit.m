function R = t200_fit(xlsxPath, outDir, doPlot)
%T200_FIT  Blue Robotics T200 스러스터 성능곡선을 18.5 V로 보간·피팅한다.
%
%  목적 3가지
%   (1) Simulink 모델에 하드코딩된 k_pos / k_neg / n_max / n_min 을 검증한다.
%   (2) 배달에서 빠진 otter_params_bow.m 의 n_uniq -> pwm_uniq 룩업을 복원한다.
%       (로깅된 PWM(spare_one..three) -> n [rad/s] 역변환에 필요)
%   (3) 추력 모델 f = k(sign n) * n * |n| 의 적합도를 정량 보고한다.
%
%  엑셀에는 10/12/14/16/18/20 V 시트만 있고 18.5 V 시트는 없다.
%  -> 18 V 와 20 V 를 PWM 격자에서 선형보간한다 (w18 = 0.75, w20 = 0.25).
%
%  출력: outDir/t200_18p5V.mat  (구조체 R)
%
%  Ref: 모델측 상수 (chart_47 = Control_Allocation_Bow_heading)
%       k_pos = 3.670142870302694e-04
%       k_neg = 2.898839656197090e-04
%       n_max = +312.5528643154  (PWM 1800)
%       n_min = -312.6052241930  (PWM 1200)

if nargin < 3, doPlot = true; end
G = 9.80665;                      % kgf -> N
PWM_LO = 1200; PWM_HI = 1800;     % Simulink Saturation 범위 (1100/1900 아님)
V_TGT  = 18.5;

%% ---------- 1. 읽기 ----------
T18 = readtable(xlsxPath,'Sheet','18 V','VariableNamingRule','preserve');
T20 = readtable(xlsxPath,'Sheet','20 V','VariableNamingRule','preserve');

pwm18 = T18{:,1};  rpm18 = T18{:,2};  fkg18 = T18{:,6};
pwm20 = T20{:,1};  rpm20 = T20{:,2};  fkg20 = T20{:,6};
assert(isequal(pwm18,pwm20), 'PWM 격자가 시트 간에 다르다');

%% ---------- 2. 18.5 V 보간 ----------
w = (V_TGT-18)/(20-18);           % 0.25
pwm  = pwm18;
rpm  = (1-w)*rpm18 + w*rpm20;     % 표의 RPM 은 항상 양수(크기)
fkgf = (1-w)*fkg18 + w*fkg20;     % 추력은 부호 있음
f    = fkgf*G;                    % [N]

% 표의 RPM 은 부호가 없다 -> 추력 부호로 회전방향을 복원한다.
sgn  = sign(f);  sgn(f==0) = 0;
n    = sgn .* rpm * 2*pi/60;      % [rad/s], 부호 포함

%% ---------- 3. 모델 작동범위로 제한 ----------
m   = pwm >= PWM_LO & pwm <= PWM_HI;
pwm = pwm(m); n = n(m); f = f(m); rpm = rpm(m); fkgf = fkgf(m);

%% ---------- 4. f = k*n*|n| 피팅 ----------
phi = n.*abs(n);                                  % 회귀자
ip  = f > 0;  in = f < 0;
k_pos_fit = (phi(ip)'*f(ip)) / (phi(ip)'*phi(ip));
k_neg_fit = (phi(in)'*f(in)) / (phi(in)'*phi(in));

fhat = zeros(size(f));
fhat(phi>=0) = k_pos_fit*phi(phi>=0);
fhat(phi< 0) = k_neg_fit*phi(phi< 0);
res  = f - fhat;
R2   = 1 - sum(res.^2)/sum((f-mean(f)).^2);

%% ---------- 5. 극한값 ----------
n_max_fit = max(n);  n_min_fit = min(n);
f_max = k_pos_fit*n_max_fit*abs(n_max_fit);
f_min = k_neg_fit*n_min_fit*abs(n_min_fit);

%% ---------- 6. n -> pwm 룩업 복원 ----------
% Simulink 1-D Lookup 은 BreakpointsForDimension1 = n_uniq 가 단조증가여야 한다.
% 데드밴드 구간(n=0) 이 여러 PWM 에 걸치므로 중복 제거가 필요하다.
[ns, idx] = sort(n);
ps = pwm(idx);
[n_uniq, ia] = unique(ns, 'stable');
pwm_uniq = zeros(size(n_uniq));
for i = 1:numel(n_uniq)
    sel = (ns == n_uniq(i));
    pwm_uniq(i) = mean(ps(sel));      % n=0 데드밴드는 PWM 중앙값으로
end
% 단조성 보장
assert(all(diff(n_uniq) > 0), 'n_uniq 가 단조증가가 아니다');

%% ---------- 7. 보고 ----------
k_pos_mdl = 3.670142870302694e-04;
k_neg_mdl = 2.898839656197090e-04;
n_max_mdl =  312.5528643154;
n_min_mdl = -312.6052241930;

fprintf('\n=== T200 @ %.1f V  (18V/20V 선형보간, w20=%.2f) ===\n', V_TGT, w);
fprintf('PWM 범위        : %d .. %d  (%d 점)\n', min(pwm), max(pwm), numel(pwm));
fprintf('n 범위          : %+.4f .. %+.4f rad/s  (%.1f .. %.1f RPM)\n', ...
        n_min_fit, n_max_fit, n_min_fit*60/2/pi, n_max_fit*60/2/pi);
fprintf('f 범위          : %+.3f .. %+.3f N\n', min(f), max(f));
fprintf('\n           %-22s %-22s %-10s\n','피팅값','모델 하드코딩','상대오차');
fprintf('k_pos    %-22.12e %-22.12e %+7.3f %%\n', k_pos_fit, k_pos_mdl, 100*(k_pos_fit/k_pos_mdl-1));
fprintf('k_neg    %-22.12e %-22.12e %+7.3f %%\n', k_neg_fit, k_neg_mdl, 100*(k_neg_fit/k_neg_mdl-1));
fprintf('n_max    %-22.6f %-22.6f %+7.3f %%\n', n_max_fit, n_max_mdl, 100*(n_max_fit/n_max_mdl-1));
fprintf('n_min    %-22.6f %-22.6f %+7.3f %%\n', n_min_fit, n_min_mdl, 100*(n_min_fit/n_min_mdl-1));
fprintf('\nf = k*n*|n| 적합도 : R2 = %.5f, RMSE = %.4f N, max|res| = %.4f N\n', ...
        R2, sqrt(mean(res.^2)), max(abs(res)));
fprintf('정방향 한계 f_max = %+.3f N   역방향 한계 f_min = %+.3f N (비 %.3f)\n', ...
        f_max, f_min, abs(f_min/f_max));
fprintf('데드밴드(n=0) PWM 구간 : %d .. %d us (중앙 %.1f)\n', ...
        min(pwm(n==0)), max(pwm(n==0)), mean(pwm(n==0)));
fprintf('룩업 테이블 길이 : %d\n', numel(n_uniq));

%% ---------- 8. 저장 ----------
R = struct('V',V_TGT,'pwm',pwm,'n',n,'f',f,'rpm',rpm,'fkgf',fkgf, ...
           'k_pos',k_pos_fit,'k_neg',k_neg_fit, ...
           'k_pos_mdl',k_pos_mdl,'k_neg_mdl',k_neg_mdl, ...
           'n_max',n_max_fit,'n_min',n_min_fit, ...
           'n_max_mdl',n_max_mdl,'n_min_mdl',n_min_mdl, ...
           'f_max',f_max,'f_min',f_min, ...
           'n_uniq',n_uniq,'pwm_uniq',pwm_uniq, ...
           'R2',R2,'rmse',sqrt(mean(res.^2)), ...
           'PWM_LO',PWM_LO,'PWM_HI',PWM_HI);

if ~isfolder(outDir), mkdir(outDir); end
save(fullfile(outDir,'t200_18p5V.mat'),'-struct','R');
fprintf('저장: %s\n', fullfile(outDir,'t200_18p5V.mat'));

%% ---------- 9. 그림 ----------
if doPlot
    fig = figure('Position',[80 80 1200 420],'Color','w');
    subplot(1,3,1)
      plot(pwm, f, 'k.-'); grid on; hold on
      yline(0,'r:'); xline(1500,'r:');
      xlabel('PWM [\mus]'); ylabel('Thrust [N]'); title('T200 @18.5V  PWM vs Thrust')
    subplot(1,3,2)
      plot(pwm, n*60/2/pi, 'b.-'); grid on
      xlabel('PWM [\mus]'); ylabel('n [RPM]'); title('PWM vs signed RPM')
    subplot(1,3,3)
      plot(n, f, 'k.'); grid on; hold on
      nn = linspace(min(n),max(n),400)';
      ff = nn; ff(nn>=0)=k_pos_fit*nn(nn>=0).^2; ff(nn<0)=-k_neg_fit*nn(nn<0).^2;
      plot(nn, ff, 'r-','LineWidth',1.2)
      xlabel('n [rad/s]'); ylabel('Thrust [N]')
      title(sprintf('f = k n|n|   R^2=%.4f',R2)); legend('data','fit','Location','northwest')
    exportgraphics(fig, fullfile(outDir,'..','figs','t200_fit_18p5V.png'),'Resolution',140);
end
end
