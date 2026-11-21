function mdl = build_tug1_slx(mdl, withAlloc)
%BUILD_TUG1_SLX  식별된 Tug1 3-DOF 운동모델을 Simulink 모델로 생성한다.
%
%  mdl = build_tug1_slx()                      -> 'tug1_3dof'
%  mdl = build_tug1_slx('tug1_3dof_alloc',true) -> 추력배분 전단 포함
%
%  ---------------------------------------------------------------
%  구조
%  ---------------------------------------------------------------
%   [From Workspace TAU_TS] -> [Subsystem Tug1_3DOF] -> [To Workspace YSIM]
%
%   Subsystem Tug1_3DOF 내부:
%     In1  tau (3x1)  ----\
%     Constant TUG1_P -----> [MATLAB Function tug1_dyn] -> [Integrator] -> Out1 (6x1)
%                       /                                        |
%                       \----------------- s (6x1) <-------------/
%
%  withAlloc=true 이면 입력이 f = [f1(좌현); f2(우현); f3(바우)] 가 되고
%  Gain(행렬) T = [1 1 0; 0 0 1; d -d la] 로 tau 를 만든다 (실기와 동일 규약).
%
%  ★ 왜 서브시스템으로 묶는가
%  나중 RL 작업에서 이 서브시스템만 복사해 환경 모델로 쓰면 된다.
%  최상위의 From/To Workspace 는 검증용 하네스다.
%
%  ★ 솔버
%  fixed-step ode4, h = Ts = 0.02 s. tug_sim 의 RK4 와 일치시키려면
%  tau 를 '선형보간' 해야 한다 (From Workspace 의 ZOH 를 끈다).
%  tug_sim 은 중간스텝에서 tm = 0.5*(t1+t2) 를 쓰기 때문이다.

if nargin < 1 || isempty(mdl),  mdl = 'tug1_3dof';  end
if nargin < 2 || isempty(withAlloc), withAlloc = false; end

P = tug_params();

if bdIsLoaded(mdl), close_system(mdl, 0); end
new_system(mdl);
open_system(mdl);

sub = [mdl '/Tug1_3DOF'];
add_block('built-in/Subsystem', sub, 'Position', [240 100 420 200]);

% ---------------- 서브시스템 내부 ----------------
% ★ add_block('built-in/Subsystem') 은 '빈' 서브시스템을 만든다.
%   라이브러리 브라우저에서 드래그할 때와 달리 In1/Out1 이 들어 있지 않으므로
%   포트를 직접 만들어 준다 (지울 기본 배선도 없다).
add_block('built-in/Inport',  [sub '/tau'], ...
    'Position',[30 103 60 117], 'PortDimensions','3');
add_block('built-in/Outport', [sub '/states'], 'Position',[480 103 510 117]);

add_block('simulink/Sources/Constant', [sub '/p'], ...
    'Value','TUG1_P', 'Position',[30 168 90 192]);

add_block('simulink/User-Defined Functions/MATLAB Function', [sub '/dyn'], ...
    'Position',[150 80 290 190]);
code = fileread(which('tug1_dyn'));
sfr  = sfroot;
ch   = sfr.find('-isa','Stateflow.EMChart','Path',[sub '/dyn']);
ch.Script = code;

add_block('simulink/Continuous/Integrator', [sub '/x'], ...
    'InitialCondition','TUG1_X0', 'Position',[340 95 380 135]);

% 배선: dyn 의 입력 순서 = (s, tau, p)
add_line(sub, 'tau/1', 'dyn/2', 'autorouting','on');
add_line(sub, 'p/1',   'dyn/3', 'autorouting','on');
add_line(sub, 'dyn/1', 'x/1',   'autorouting','on');
add_line(sub, 'x/1',   'dyn/1', 'autorouting','on');
add_line(sub, 'x/1',   'states/1', 'autorouting','on');

% ---------------- 최상위 하네스 ----------------
add_block('simulink/Sources/From Workspace', [mdl '/tau_in'], ...
    'VariableName','TAU_TS', 'Interpolate','on', 'ZeroCross','off', ...
    'OutputAfterFinalValue','Holding final value', 'Position',[60 120 170 160]);

add_block('simulink/Sinks/To Workspace', [mdl '/YSIM'], ...
    'VariableName','YSIM', 'SaveFormat','Array', 'SampleTime','-1', ...
    'Position',[500 125 560 155]);

if withAlloc
    % f = [f1; f2; f3] -> tau = T*f
    set_param([mdl '/tau_in'], 'VariableName','F_TS');
    add_block('simulink/Math Operations/Gain', [mdl '/T_alloc'], ...
        'Gain', mat2str(P.T), 'Multiplication','Matrix(K*u)', ...
        'Position',[200 123 250 157]);
    add_line(mdl, 'tau_in/1',  'T_alloc/1',   'autorouting','on');
    add_line(mdl, 'T_alloc/1', 'Tug1_3DOF/1','autorouting','on');
else
    add_line(mdl, 'tau_in/1', 'Tug1_3DOF/1', 'autorouting','on');
end
add_line(mdl, 'Tug1_3DOF/1', 'YSIM/1', 'autorouting','on');

% ---------------- 솔버 ----------------
set_param(mdl, 'SolverType','Fixed-step', 'Solver','ode4', ...
    'FixedStep', sprintf('%.10g', P.Ts), 'StartTime','0', 'StopTime','10', ...
    'SaveOutput','off', 'SaveTime','off');

save_system(mdl, fullfile('..','out',[mdl '.slx']));
fprintf('생성: ..\\out\\%s.slx  (ode4, h = %.3f s, 추력배분 전단 = %d)\n', ...
    mdl, P.Ts, withAlloc);
end
