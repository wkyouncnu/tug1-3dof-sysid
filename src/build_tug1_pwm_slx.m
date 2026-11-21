function mdl = build_tug1_pwm_slx(mdl)
%BUILD_TUG1_PWM_SLX  입력이 'PWM' 인 Tug1 3-DOF Simulink 운동모델을 생성한다.
%
%  mdl = build_tug1_pwm_slx()            -> 'tug1_3dof_pwm'
%
%  ---------------------------------------------------------------
%  구조 (tau 입력판 tug1_3dof.slx 와 동역학은 완전히 동일)
%  ---------------------------------------------------------------
%   [From Workspace PWM_TS]      3x1 [us]  (spare_one/two/three = 좌현/우현/바우)
%        |
%   [Saturation 1200..1800]                  실기 PWM 권한
%        |
%   [1-D Lookup  T200_PWM -> T200_F]         ★ 18.5 V 실측 PWM-추력 곡선
%        |                                     (데드밴드는 표 자체가 0 이다)
%   [Gain  T' = [1 1 0; 0 0 1; d -d la]]     tau = T*f
%        |
%   [Subsystem Tug1_3DOF] -> [To Workspace YSIM]
%
%  ★ 왜 tau 가 아니라 PWM 을 입력으로 두는가
%  실기에서 ESC 가 받는 신호는 PWM 이다. 로그의 taux/tauy/taun 은 '배분 전'
%  지령이라 실제 작용력이 아니다 (tau_from_log.m 참조). 따라서 "같은 PWM 을
%  넣으면 같은 궤적이 나오는가" 가 모델의 최종 검증이고, RL 환경에서도
%  정책 출력 -> PWM -> 추력 경로를 그대로 쓸 수 있다.
%
%  ★ tau 입력판과의 차이 (불가피한 잔차)
%  식별 파이프라인은 PWM 을 50 Hz 격자로 선형보간한 뒤 tau 를 계산했고,
%  tug_sim 은 RK4 중간스텝에서 'tau' 를 선형보간한다. 이 모델은 'PWM' 을
%  보간한 뒤 비선형 룩업을 통과시키므로 중간스텝 값이 미세하게 다르다
%  (데드밴드 경계에서 최대). run_slx_val.m 이 이 차이를 수치로 보고한다.
%
%  ★ 실행 전 베이스워크스페이스에 필요한 변수
%    T200_PWM, T200_F : 룩업표 (run_slx_val.m 이 자동 할당)
%    TUG1_P, TUG1_X0  : 모델 파라미터 / 초기상태
%    PWM_TS           : timeseries(pwm [N x 3], t)

if nargin < 1 || isempty(mdl), mdl = 'tug1_3dof_pwm'; end

P = tug_params();

% tau 입력판을 먼저 만든 뒤 전단만 갈아끼운다 (동역학 서브시스템 코드 공유)
build_tug1_slx(mdl, false);

delete_line(mdl, 'tau_in/1', 'Tug1_3DOF/1');
set_param([mdl '/tau_in'], 'VariableName','PWM_TS', 'Position',[25 120 125 160]);
set_param([mdl '/tau_in'], 'Name','pwm_in');

add_block('simulink/Discontinuities/Saturation', [mdl '/sat'], ...
    'UpperLimit', sprintf('%g',P.PWM_HI), 'LowerLimit', sprintf('%g',P.PWM_LO), ...
    'Position',[150 125 180 155]);

add_block('simulink/Lookup Tables/1-D Lookup Table', [mdl '/T200'], ...
    'BreakpointsSpecification','Explicit values', ...
    'BreakpointsForDimension1','T200_PWM', 'Table','T200_F', ...
    'InterpMethod','Linear point-slope', 'ExtrapMethod','Clip', ...
    'Position',[205 120 265 160]);

add_block('simulink/Math Operations/Gain', [mdl '/T_alloc'], ...
    'Gain', mat2str(P.T), 'Multiplication','Matrix(K*u)', ...
    'Position',[290 123 340 157]);

add_line(mdl, 'pwm_in/1',  'sat/1',       'autorouting','on');
add_line(mdl, 'sat/1',     'T200/1',      'autorouting','on');
add_line(mdl, 'T200/1',    'T_alloc/1',   'autorouting','on');
add_line(mdl, 'T_alloc/1', 'Tug1_3DOF/1', 'autorouting','on');

set_param([mdl '/YSIM'], 'SampleTime', sprintf('%.10g', P.Ts));

save_system(mdl, fullfile('..','out',[mdl '.slx']));
fprintf('생성: ..\\out\\%s.slx  (PWM 입력, ode4 h = %.3f s)\n', mdl, P.Ts);
end
