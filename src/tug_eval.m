function E = tug_eval(Th, runs, P, opt)
%TUG_EVAL  주어진 파라미터로 런 집합을 롤아웃 평가한다.
%
%  E = tug_eval(Th, runs, P, opt)
%
%  opt.minseg_s (3.0) : 이보다 짧은 연속 활성구간은 버린다
%  opt.horiz_s  ([])  : 비어 있으면 구간 전체를 한 번에 롤아웃(= 최악조건).
%                       숫자면 그 길이로 창을 끊어 각 창을 독립 롤아웃한다.
%  opt.Nsteps   ([])  : N-step 오차곡선용 스텝수 벡터 (예: [1 5 25 50 100 250 500])
%
%  출력 (전부 활성구간만 집계)
%    E.rmse  : [u v r x y psi] RMSE
%    E.nrmse : 각 채널 RMSE / 해당 채널 측정 표준편차
%    E.zeta  : (1/6)*sum(nrmse)         <- 문헌 공통 복합지표
%    E.ate   : 궤적 평균 위치오차 [m]   (sqrt(ex^2+ey^2) 평균)
%    E.ate_rel: ATE / 주행거리
%    E.curve : N-step RMSE 곡선 (opt.Nsteps 지정시)
%    E.per   : 런별 표
%
%  ★ 1-step 적합이 아니라 '완전 재귀 롤아웃'으로 평가한다.
%    사용자 요구("궤적이 맞아야 한다")가 곧 이 지표다.

if nargin < 4, opt = struct; end
if ~isfield(opt,'minseg_s'), opt.minseg_s = 3.0; end
if ~isfield(opt,'horiz_s'),  opt.horiz_s  = [];  end
if ~isfield(opt,'Nsteps'),   opt.Nsteps   = [];  end
if ~isfield(opt,'split'),    opt.split    = 'all'; end

Ts = P.Ts;
ch = {'u','v','r','x','y','psi'};
SE = zeros(1,6);  NN = 0;                 % 제곱오차 합
SD = cell(1,6);   for i=1:6, SD{i} = []; end
ae = [];  dist = 0;  aesum = 0;  aen = 0;  nwin = 0;
per = struct([]);  np = 0;

if ~isempty(opt.Nsteps)
    cu = zeros(numel(opt.Nsteps), 6);  cn = zeros(numel(opt.Nsteps), 1);
else
    cu = [];  cn = [];
end

for ir = 1:numel(runs)
    R  = runs(ir).R;
    if ~strcmp(opt.split,'all') && ~strcmp(R.split, opt.split), continue, end
    sg = tug_segs(R.act, round(opt.minseg_s/Ts));
    if isempty(sg), continue, end
    rs = zeros(1,6);  rn = 0;  rae = 0;  ran = 0;  rdist = 0;

    for is = 1:size(sg,1)
        i0 = sg(is,1);  i1 = sg(is,2);
        if isempty(opt.horiz_s)
            W = [i0 i1];
        else
            L = round(opt.horiz_s/Ts);
            s0 = (i0:L:i1).';  s1 = min(s0+L-1, i1);
            W  = [s0 s1];  W = W(W(:,2)-W(:,1) >= round(1.0/Ts), :);
        end
        for iw = 1:size(W,1)
            a = W(iw,1);  b = W(iw,2);
            tau = R.tau(a:b, :);
            Zm  = [R.u(a:b), R.v(a:b), R.r(a:b), R.x(a:b), R.y(a:b), R.psi(a:b)];
            % 위치/방위는 구간 시작을 원점으로 (절대 GPS 원점 무관)
            % ★ 방위를 0 으로 되돌리면 좌표계도 같이 -psi0 만큼 돌아간다.
            %   변위를 함께 회전시키지 않으면 '모델이 틀린 것'이 아니라
            %   '좌표계가 돌아간 것'을 오차로 재게 된다 (x 오차 0.14 -> 4.06 m).
            p0 = Zm(1,6);
            dX = Zm(:,4) - Zm(1,4);
            dY = Zm(:,5) - Zm(1,5);
            Zm(:,4) =  cos(p0)*dX + sin(p0)*dY;
            Zm(:,5) = -sin(p0)*dX + cos(p0)*dY;
            Zm(:,6) = Zm(:,6) - p0;
            x0 = [Zm(1,1:3), 0, 0, 0];
            Yp = tug_sim(Th, tau, Ts, x0, P.la);
            er = Yp - Zm;
            er(:,6) = wrapToPi(er(:,6));

            SE = SE + sum(er.^2, 1);   NN = NN + size(er,1);
            rs = rs + sum(er.^2, 1);   rn = rn + size(er,1);
            for i = 1:6, SD{i} = [SD{i}; Zm(:,i)]; end

            dp = sqrt(er(:,4).^2 + er(:,5).^2);
            aesum = aesum + sum(dp);  aen = aen + numel(dp);
            rae   = rae   + sum(dp);  ran = ran + numel(dp);
            dd = sum(sqrt(diff(Zm(:,4)).^2 + diff(Zm(:,5)).^2));
            dist = dist + dd;  rdist = rdist + dd;  nwin = nwin + 1;

            if ~isempty(opt.Nsteps)
                for q = 1:numel(opt.Nsteps)
                    n = opt.Nsteps(q);
                    if size(er,1) >= n+1
                        cu(q,:) = cu(q,:) + er(n+1,:).^2;
                        cn(q)   = cn(q) + 1;
                    end
                end
            end
        end
    end
    if rn > 0
        np = np + 1;
        per(np).name  = R.name;   per(np).type = R.type;   per(np).split = R.split;
        per(np).rmse  = sqrt(rs/rn);
        per(np).ate   = rae/max(ran,1);
        per(np).dist  = rdist;
        per(np).ate_rel = per(np).ate / max(rdist,eps);
    end
end

E = struct();
E.n      = NN;
E.rmse   = sqrt(SE/max(NN,1));
sd       = cellfun(@(z) std(z), SD);
E.sd     = sd;
E.nrmse  = E.rmse ./ max(sd, eps);
E.zeta   = mean(E.nrmse);
E.ate    = aesum/max(aen,1);
E.dist   = dist;
E.nwin   = nwin;
%  ★ 창 하나당 평균 주행거리로 나눈다 (런 전체 거리로 나누면 무의미했다)
E.dist_w = dist/max(nwin,1);
E.ate_rel= E.ate / max(E.dist_w, eps);
E.per    = per;
E.ch     = {ch};
if ~isempty(opt.Nsteps)
    E.Nsteps = opt.Nsteps;
    E.curve  = sqrt(cu ./ max(cn,1));
    E.curve_n = cn;
end
end
