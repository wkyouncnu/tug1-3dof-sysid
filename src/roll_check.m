%ROLL_CHECK  ★ "3자유도니까 roll 은 무시해도 되는가" 를 데이터로 판정한다
%
%  검사 3가지
%   (1) 실제 heel/trim 크기        : phi, theta 분포 (전 분할)
%   (2) 기하학적 누설 크기          : 바우추력 수평성분 손실 cos(phi),
%                                    횡가속 중력누설 g*sin(phi) 의 '순(net)' 크기
%   (3) ★ 결정적 검사 — 3자유도 모델의 sway/yaw 롤아웃 잔차가
%        phi 와 상관되는가. 상관이 없으면 roll 은 '빠진 물리' 가 아니다.

P = tug_params();
if ~exist('S','var') || isempty(S), S = load('..\out\tug1_runs.mat'); S = S.S; end
runs = S.runs;
Zq   = load('..\out\tug1_oe.mat');  Q = Zq.Q;
iD   = find(strcmp({Q.id},'D'),1);   ThD  = Q(iD).Th;
iF3  = find(strcmp({Q.id},'F3'),1);  ThF3 = Q(iF3).Th;

Ts = P.Ts;  g = P.g;
PH = []; TH = []; RESV = []; RESR = []; RESVD = []; UU = []; RR = [];
nok = 0;

for ir = 1:numel(runs)
    R = runs(ir).R;
    if ~ismember(R.split, {'val','test'}), continue, end
    try
        ul = ulogreader(R.file);  L = readTopicMsgs(ul);
        k  = find(strcmp(L.TopicNames,'vehicle_attitude'),1);
        if isempty(k), continue, end
        AT = L.TopicMessages{k};
    catch
        continue
    end
    ta = seconds(AT.timestamp);  ta = ta - ta(1);
    q  = double(AT.q);
    % FRD/NED 쿼터니언 -> roll, pitch
    phi_q = atan2(2*(q(:,1).*q(:,2)+q(:,3).*q(:,4)), 1-2*(q(:,2).^2+q(:,3).^2));
    sth   = max(min(2*(q(:,1).*q(:,3)-q(:,4).*q(:,2)), 1), -1);
    th_q  = asin(sth);

    phi = interp1(ta, unwrap(phi_q), R.t, 'linear','extrap');
    tht = interp1(ta, th_q,          R.t, 'linear','extrap');

    % --- 3자유도 롤아웃 잔차 (5 s 창, tug_eval 과 동일 규약) ---
    sg = tug_segs(R.act, round(3.0/Ts));
    Lw = round(5.0/Ts);
    for is = 1:size(sg,1)
        for a = sg(is,1):Lw:(sg(is,2)-Lw+1)
            b  = a + Lw - 1;
            tau= R.tau(a:b,:);
            Zm = [R.u(a:b), R.v(a:b), R.r(a:b), R.x(a:b), R.y(a:b), R.psi(a:b)];
            p0 = Zm(1,6);
            dX = Zm(:,4)-Zm(1,4);  dY = Zm(:,5)-Zm(1,5);
            Zm(:,4) =  cos(p0)*dX + sin(p0)*dY;
            Zm(:,5) = -sin(p0)*dX + cos(p0)*dY;
            Zm(:,6) = Zm(:,6) - p0;
            x0 = [Zm(1,1:3), 0, 0, 0];
            Y3 = tug_sim(ThF3, tau, Ts, x0, P.la);
            YD = tug_sim(ThD,  tau, Ts, x0, P.la);
            RESV  = [RESV;  Y3(:,2)-Zm(:,2)];   %#ok<AGROW>
            RESR  = [RESR;  Y3(:,3)-Zm(:,3)];   %#ok<AGROW>
            RESVD = [RESVD; YD(:,2)-Zm(:,2)];   %#ok<AGROW>
            PH    = [PH;    phi(a:b)];          %#ok<AGROW>
            TH    = [TH;    tht(a:b)];          %#ok<AGROW>
            UU    = [UU;    Zm(:,1)];           %#ok<AGROW>
            RR    = [RR;    Zm(:,3)];           %#ok<AGROW>
        end
    end
    nok = nok + 1;
end

fprintf('\n=== (1) 실제 heel / trim  (val+test %d런, n=%d) ===\n', nok, numel(PH));
d = @(z) [rad2deg(mean(z)) rad2deg(std(z)) rad2deg(prctile(abs(z),95)) rad2deg(max(abs(z)))];
fprintf('  phi  (roll ) [deg]  mean %+6.2f  std %5.2f  p95|.| %5.2f  max|.| %5.2f\n', d(PH));
fprintf('  theta(pitch) [deg]  mean %+6.2f  std %5.2f  p95|.| %5.2f  max|.| %5.2f\n', d(TH));

fprintf('\n=== (2) 기하학적 누설 ===\n');
p95 = prctile(abs(PH),95);  pmx = max(abs(PH));
fprintf('  바우 횡추력 수평성분 손실 1-cos(phi): p95 %.3f %%   max %.3f %%\n', ...
    100*(1-cos(p95)), 100*(1-cos(pmx)));
fprintf('  (참고) 중력 단독 누설 g*sin(phi)     : p95 %.3f   max %.3f m/s^2\n', ...
    g*sin(p95), g*sin(pmx));
fprintf('  ※ 부유체는 중력+부력이 함께 기울어 net 가 거의 상쇄된다.\n');
fprintf('     정heel 평형에서 body-y 방향 net 정수압력 ~ 0 -> 위 값은 상한이다.\n');

fprintf('\n=== (3) ★ 3자유도 롤아웃 잔차 vs roll 상관 ===\n');
cc = @(x,y) corr(x(:), y(:));
fprintf('  corr(res_v , phi      ) = %+7.4f\n', cc(RESV, PH));
fprintf('  corr(res_v , sin(phi) ) = %+7.4f\n', cc(RESV, sin(PH)));
fprintf('  corr(res_v , |phi|    ) = %+7.4f\n', cc(RESV, abs(PH)));
fprintf('  corr(res_r , phi      ) = %+7.4f\n', cc(RESR, PH));
fprintf('  corr(|res_v|, |phi|   ) = %+7.4f\n', cc(abs(RESV), abs(PH)));
fprintf('  (대조) corr(res_v, u)   = %+7.4f   corr(res_v, r) = %+7.4f\n', cc(RESV,UU), cc(RESV,RR));
fprintf('  (대조) corr(phi,   r)   = %+7.4f   corr(phi,   u) = %+7.4f\n', cc(PH,RR), cc(PH,UU));

% roll 을 '추가 회귀항' 으로 넣으면 잔차가 얼마나 설명되는가
A  = [sin(PH), abs(PH), ones(numel(PH),1)];
b1 = RESV;  c1 = A\b1;  r2v = 1 - sum((b1-A*c1).^2)/sum((b1-mean(b1)).^2);
b2 = RESR;  c2 = A\b2;  r2r = 1 - sum((b2-A*c2).^2)/sum((b2-mean(b2)).^2);
fprintf('\n  roll 항 [sin(phi), |phi|, 1] 로 잔차를 회귀하면:\n');
fprintf('    res_v 설명력 R^2 = %.4f   (잔차 std %.4f -> %.4f m/s)\n', ...
    r2v, std(b1), std(b1-A*c1));
fprintf('    res_r 설명력 R^2 = %.4f   (잔차 std %.4f -> %.4f rad/s)\n', ...
    r2r, std(b2), std(b2-A*c2));

save('..\out\tug1_rollchk.mat','PH','TH','RESV','RESR','RESVD','UU','RR','-v7.3');
