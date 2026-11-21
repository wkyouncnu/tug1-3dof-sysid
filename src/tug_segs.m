function S = tug_segs(act, minlen)
%TUG_SEGS  논리마스크 -> 연속구간 [i0 i1] 목록
if nargin < 2, minlen = 1; end
a  = [false; act(:); false];
i0 = find(diff(a) ==  1);
i1 = find(diff(a) == -1) - 1;
k  = (i1 - i0 + 1) >= minlen;
S  = [i0(k), i1(k)];
end
