function S = tug_build_dataset(logDir, outMat, P, T200, opt)
%TUG_BUILD_DATASET  tug1 ULog 전체 -> 식별용 데이터셋 + 기동별 train/val/test 분할
%
%  S = tug_build_dataset(logDir, outMat, P, T200, opt)
%
%  logDir : ...\log_261120\tug1   (루트의 *.ulg 만. _short_under5s 는 제외)
%  outMat : 저장 경로 (.mat)
%  opt.min_act_s (3.0) : 제어 ON 유효구간이 이보다 짧으면 버린다
%  opt.holdout   ([])  : 'auto' 분할 외에 강제 테스트로 보낼 파일명 cell
%
%  ─────────────────────────────────────────────────────────────
%  분할 규칙 (사용자 요구: val/test 를 나누고 궤적까지 맞춘다)
%    * 분할 단위는 "파일(= 하나의 기동)" 이다. 한 기동을 앞뒤로 자르지 않는다.
%      (CLAUDE.md Phase 1 설계원칙 4)
%    * 기동 종류별로 층화(stratified): 지속시간 내림차순 정렬 후
%        idx mod 5 == 0 -> test, == 1 -> val, 나머지 -> train
%      => 각 종류의 가장 긴 기동이 test 로 가므로
%         "훈련보다 큰 진폭을 test 에 배치한다"(Liu 2024) 가 자동 충족된다.
%  ─────────────────────────────────────────────────────────────

if nargin < 5, opt = struct; end
if ~isfield(opt,'min_act_s'), opt.min_act_s = 3.0; end
if ~isfield(opt,'holdout'),   opt.holdout   = {};  end

D = dir(fullfile(logDir,'*.ulg'));
assert(~isempty(D), 'ulg 파일이 없다: %s', logDir);
fprintf('ULog %d 개 발견\n', numel(D));

runs = struct([]);  k = 0;  nbad = 0;
for i = 1:numel(D)
    fn = D(i).name;
    R  = ulog2run(fullfile(logDir,fn), P, T200, struct('raw',true));
    if ~R.ok
        fprintf('  [skip] %-52s %s\n', fn, R.msg);  nbad = nbad+1;  continue
    end
    if R.n_act * P.Ts < opt.min_act_s
        fprintf('  [skip] %-52s 유효구간 %.1f s\n', fn, R.n_act*P.Ts);
        nbad = nbad+1;  continue
    end
    R.name = fn;
    R.type = local_type(fn);
    k = k+1;  runs(k).R = R;                      %#ok<AGROW>
    if mod(k,10)==0, fprintf('  %3d / %3d\n', i, numel(D)); end
end
fprintf('유효 런 %d 개 (제외 %d)\n', k, nbad);

%% ---------- 분할 ----------
types = unique(cellfun(@(x)x.type, {runs.R}, 'UniformOutput', false));
split = repmat("train", 1, k);
dur   = cellfun(@(x)x.n_act*P.Ts, {runs.R});
tp    = cellfun(@(x)string(x.type), {runs.R});

for it = 1:numel(types)
    sel = find(tp == string(types{it}));
    [~, o] = sort(dur(sel), 'descend');
    sel = sel(o);
    for j = 1:numel(sel)
        switch mod(j-1, 5)
            case 0, split(sel(j)) = "test";
            case 1, split(sel(j)) = "val";
        end
    end
    % 종류별 런이 1개뿐이면 train 으로 둔다(분할 불가)
    if numel(sel) == 1, split(sel) = "train"; end
end
for j = 1:k
    if any(strcmp(runs(j).R.name, opt.holdout)), split(j) = "test"; end
end
for j = 1:k, runs(j).R.split = char(split(j)); end

%% ---------- 요약 ----------
fprintf('\n%-18s %5s %5s %5s | %8s %8s %8s\n', ...
        'type','trn','val','tst','t_trn','t_val','t_tst');
for it = 1:numel(types)
    sel = tp == string(types{it});
    n = [sum(sel & split=="train") sum(sel & split=="val") sum(sel & split=="test")];
    s = [sum(dur(sel & split=="train")) sum(dur(sel & split=="val")) sum(dur(sel & split=="test"))];
    fprintf('%-18s %5d %5d %5d | %8.1f %8.1f %8.1f\n', types{it}, n, s);
end
fprintf('%-18s %5d %5d %5d | %8.1f %8.1f %8.1f\n','TOTAL', ...
        sum(split=="train"),sum(split=="val"),sum(split=="test"), ...
        sum(dur(split=="train")),sum(dur(split=="val")),sum(dur(split=="test")));

%% ---------- 전역 진단 (실험 규약 검증) ----------
g = struct();
g.tauy_cmd_max = max(cellfun(@(x)x.chk.tauy_cmd_max, {runs.R}));
g.u3N_err      = max(cellfun(@(x)x.chk.u3N_err,      {runs.R}));
g.Nres_err     = max(cellfun(@(x)x.chk.Nres_err,     {runs.R}));
g.u_rms        = max(cellfun(@(x)gf(x,'u_rms_diff'),   {runs.R}));
g.v_rms        = max(cellfun(@(x)gf(x,'v_rms_diff'),   {runs.R}));
g.psi_rms      = max(cellfun(@(x)gf(x,'psi_rms_diff'), {runs.R}));
g.acc_rms      = max(cellfun(@(x)gf(x,'acc_rms_diff'), {runs.R}));
g.gps_eph      = max(cellfun(@(x)gf(x,'gps_eph'),      {runs.R}));
g.gps_fix      = min(cellfun(@(x)gf(x,'gps_fix'),      {runs.R}));
g.sat_frac     = max(cellfun(@(x)x.Dtau.sat_frac,  {runs.R}));
g.db_frac      = max(cellfun(@(x)x.Dtau.db_frac,   {runs.R}));
g.fq_rms       = max(cell2mat(cellfun(@(x)x.Dtau.f_quad_rms, {runs.R}, 'UniformOutput',false)'),[],1);
g.fm_rms       = max(cell2mat(cellfun(@(x)x.Dtau.f_mot_rms,  {runs.R}, 'UniformOutput',false)'),[],1);

rng_ = @(f) [min(cellfun(@(x)min(x.(f)(x.act)), {runs.R})), ...
             max(cellfun(@(x)max(x.(f)(x.act)), {runs.R}))];
g.u_rng = rng_('u');  g.v_rng = rng_('v');  g.r_rng = rng_('r');
TA = cell2mat(cellfun(@(x)x.tau(x.act,:), {runs.R}, 'UniformOutput', false)');
g.tau_rng = [min(TA,[],1); max(TA,[],1)];

fprintf('\n=== 전역 진단 ===\n');
fprintf('tauy 지령 최대 |.|        : %.3e   (0 이어야 한다: sway 스틱 없음)\n', g.tauy_cmd_max);
fprintf('데이지체인 u3N / Nres 오차: %.3e / %.3e  (원시격자, 0 이어야 한다)\n', g.u3N_err, g.Nres_err);
fprintf('상태 독립재계산 최대오차  : u %.4f m/s, v %.4f m/s, psi %.4f rad\n', g.u_rms, g.v_rms, g.psi_rms);
fprintf('IMU 대조(중력보정) 최대   : %.3f m/s^2\n', g.acc_rms);
fprintf('GPS fix >= %d, eph <= %.2f m\n', g.gps_fix, g.gps_eph);
fprintf('PWM 포화율 <= %.3f, 데드밴드율 <= %.3f\n', g.sat_frac, g.db_frac);
fprintf('f 경로차 RMS  2차모델 [%.3f %.3f %.3f] N  motor경로 [%.3f %.3f %.3f] N\n', g.fq_rms, g.fm_rms);
fprintf('여기범위  u [%+.2f %+.2f] m/s   v [%+.2f %+.2f] m/s   r [%+.2f %+.2f] rad/s\n', ...
        g.u_rng, g.v_rng, g.r_rng);
fprintf('실제작용 tau_x [%+.1f %+.1f] N  tau_y [%+.1f %+.1f] N  tau_N [%+.1f %+.1f] Nm\n', ...
        g.tau_rng(:,1), g.tau_rng(:,2), g.tau_rng(:,3));

%% ---------- 저장 ----------
S = struct('runs', runs, 'types', {types}, 'diag', g, 'P', P, ...
           'n_run', k, 'built', datetime('now'));
od = fileparts(outMat);
if ~isempty(od) && ~isfolder(od), mkdir(od); end
save(outMat, 'S', '-v7.3');
fprintf('\n저장: %s\n', outMat);
end

% =====================================================================
function t = local_type(fn)
% "zigzag_log_351_2026-...ulg" -> "zigzag"
i = strfind(fn, '_log_');
if isempty(i), t = 'unknown'; else, t = fn(1:i(1)-1); end
end

function v = gf(x, f)
if isfield(x.chk, f), v = x.chk.(f); else, v = NaN; end
if isempty(v), v = NaN; end
v = v(1);
end
