function out = ncorr_virtual_extensometer(sample_dir, varargin)
% NCORR_VIRTUAL_EXTENSOMETER  Two-point (virtual extensometer) strain from an image stack.
%
%   Tracks a few small speckle subsets at each of two "knife edge" locations
%   through the image stack and reports the strain from their relative motion.
%   No full-field DIC / strain-field calculation is done, so it is fast
%   (seconds for hundreds of frames) and is meant for direct comparison with
%   a physical extensometer or with the full-field results.
%
%   out = ncorr_virtual_extensometer(sample_dir, Name, Value, ...)
%
%   sample_dir : folder of image frames (*.tif / *.tiff) and, optionally,
%                timestamps.csv with columns frame_index,time_s
%
%   Defining the extensometer (choose one):
%     'Center',[x y]        center of a horizontal extensometer, reference-image px
%                           (rows = several extensometers); length = GaugeMM*PxPerMm
%     'Points',[x1 y1 x2 y2] explicit edge points (rows = several)
%     (neither)             interactive: click on the reference image
%     'Mode','center'|'twopoint'   interactive style (default 'center')
%
%   Options (defaults):
%     'GaugeMM',4            extensometer gauge length (mm), used with Center
%     'PxPerMm',49.7         image scale; 49.7 px/mm = 1080p, from checkerboard calibration
%     'NumSubsets',3         subsets per edge, stacked along y (averaged -> less noise)
%     'SubsetSpacingPx',70   vertical spacing of those subsets (px)
%     'SubsetRadiusPx',35    subset half-size (px) -> 71 x 71 px subsets
%     'SearchRadiusPx',12    search range around the previous-frame position (px)
%     'OutputDir',''         where CSVs/figure go (default: sample_dir)
%     'OutputName',''        file stem (default: <sample folder name>_vext)
%     'MaxFrames',Inf        use only the first N frames
%     'SaveFigure',true      save an overview PNG
%     'Verbose',true
%
%   Method: normalized cross-correlation (normxcorr2, needs Image Processing
%   Toolbox) of each reference subset against every frame, searched around its
%   position in the previous frame, with parabolic sub-pixel refinement.
%   Displacements are measured against frame 1 (the reference).
%
%   Output CSV (<stem>.csv), one row per frame (row 1 = reference, zeros):
%     image_index, time_s, then per extensometer <name>_ :
%       strain_x     engineering strain from the x-separation of the edges
%       strain_dist  engineering strain from the Euclidean edge separation
%       u1_px v1_px  mean displacement of edge 1 (left)   (pixels)
%       u2_px v2_px  mean displacement of edge 2 (right)  (pixels)
%       corr_min     lowest correlation peak among that extensometer's subsets
%       n_valid      number of subsets with a valid match
%   Strain is a plain fraction (0.01 = 1 %). Setup is in <stem>_info.csv.
%
%   Example
%     ncorr_virtual_extensometer('...\Spec_2\spec_2-repeat_strain-image_stack', ...
%         'Center',[1009 529], 'GaugeMM',4, 'PxPerMm',49.7);

    % ------------------------------------------------------------ options
    pr = inputParser;
    addRequired(pr, 'sample_dir', @(s) ischar(s) || isstring(s));
    addParameter(pr, 'PxPerMm', 49.7, @(v) isnumeric(v) && isscalar(v) && v > 0);
    addParameter(pr, 'GaugeMM', 4, @(v) isnumeric(v) && isscalar(v) && v > 0);
    addParameter(pr, 'Center', [], @(v) isempty(v) || (isnumeric(v) && size(v,2) == 2));
    addParameter(pr, 'Points', [], @(v) isempty(v) || (isnumeric(v) && size(v,2) == 4));
    addParameter(pr, 'Mode', 'center', @(s) any(strcmpi(s, {'center','twopoint'})));
    addParameter(pr, 'NumSubsets', 3, @(v) isnumeric(v) && isscalar(v) && v >= 1);
    addParameter(pr, 'SubsetSpacingPx', 70, @(v) isnumeric(v) && isscalar(v) && v > 0);
    addParameter(pr, 'SubsetRadiusPx', 35, @(v) isnumeric(v) && isscalar(v) && v >= 5);
    addParameter(pr, 'SearchRadiusPx', 12, @(v) isnumeric(v) && isscalar(v) && v >= 2);
    addParameter(pr, 'OutputDir', '', @(s) ischar(s) || isstring(s));
    addParameter(pr, 'OutputName', '', @(s) ischar(s) || isstring(s));
    addParameter(pr, 'MaxFrames', Inf, @(v) isnumeric(v) && isscalar(v) && v >= 2);
    addParameter(pr, 'SaveFigure', true, @(v) islogical(v) || isnumeric(v));
    addParameter(pr, 'Verbose', true, @(v) islogical(v) || isnumeric(v));
    parse(pr, sample_dir, varargin{:});
    o = pr.Results;
    sample_dir = char(o.sample_dir);
    r  = round(o.SubsetRadiusPx);
    S  = round(o.SearchRadiusPx);
    m  = round(o.NumSubsets);

    if ~exist('normxcorr2', 'file')
        error('ncorr_virtual_extensometer: normxcorr2 (Image Processing Toolbox) is required.');
    end

    % ------------------------------------------------------------ frames
    files = [dir(fullfile(sample_dir, '*.tif')); dir(fullfile(sample_dir, '*.tiff'))];
    if numel(files) < 2
        error('ncorr_virtual_extensometer: need >= 2 images in %s', sample_dir);
    end
    names = natural_sort({files.name});
    n = min(numel(names), o.MaxFrames);
    names = names(1:n);
    ref = read_gray(fullfile(sample_dir, names{1}));
    [H, W] = size(ref);

    [~, sample_name] = fileparts(sample_dir);
    if isempty(sample_name)      % trailing file separator
        [~, sample_name] = fileparts(fileparts(sample_dir));
    end
    out_dir = char(o.OutputDir); if isempty(out_dir), out_dir = sample_dir; end
    if ~exist(out_dir, 'dir'), mkdir(out_dir); end
    stem = char(o.OutputName); if isempty(stem), stem = [sample_name '_vext']; end

    % ------------------------------------------------------------ define extensometers
    L_px = o.GaugeMM * o.PxPerMm;
    if ~isempty(o.Points)
        P = o.Points;
    elseif ~isempty(o.Center)
        P = [o.Center(:,1) - L_px/2, o.Center(:,2), o.Center(:,1) + L_px/2, o.Center(:,2)];
    else
        P = pick_points(ref, o.Mode, L_px);
        if isempty(P), out = []; return; end
    end
    nE = size(P, 1);

    % subset centers (integers); subset k of edge s of extensometer e
    cx = zeros(nE, 2, m);  cy = zeros(nE, 2, m);
    offs = ((1:m) - (m + 1)/2) * o.SubsetSpacingPx;
    for e = 1:nE
        for s = 1:2
            for j = 1:m
                cx(e, s, j) = round(P(e, 2*s - 1));
                cy(e, s, j) = round(P(e, 2*s) + offs(j));
            end
        end
    end
    margin = r + S + 2;
    if any(cx(:) < margin | cx(:) > W - margin | cy(:) < margin | cy(:) > H - margin)
        error('ncorr_virtual_extensometer: a subset (+search range) falls outside the image. Move the points inward or reduce SubsetRadiusPx/NumSubsets.');
    end

    % reference templates
    T = cell(nE, 2, m);
    for e = 1:nE
        for s = 1:2
            for j = 1:m
                x0 = cx(e,s,j); y0 = cy(e,s,j);
                T{e,s,j} = ref(y0-r:y0+r, x0-r:x0+r);
            end
        end
    end

    % ------------------------------------------------------------ track
    DX = zeros(n, nE, 2, m);  DY = zeros(n, nE, 2, m);  CP = ones(n, nE, 2, m);
    dprev = zeros(nE, 2, m, 2);
    t0 = tic;
    for k = 2:n
        img = read_gray(fullfile(sample_dir, names{k}));
        for e = 1:nE
            for s = 1:2
                for j = 1:m
                    [dx, dy, cp] = track_one(T{e,s,j}, img, cx(e,s,j), cy(e,s,j), r, S, ...
                                             squeeze(dprev(e,s,j,:)));
                    DX(k,e,s,j) = dx;  DY(k,e,s,j) = dy;  CP(k,e,s,j) = cp;
                    if ~isnan(dx), dprev(e,s,j,:) = [dx dy]; end
                end
            end
        end
        if o.Verbose && (mod(k, 25) == 0 || k == n)
            fprintf('  frame %d / %d  (%.1f s)\n', k, n, toc(t0));
        end
    end

    % ------------------------------------------------------------ strains
    nm = cell(1, nE);
    for e = 1:nE, nm{e} = sprintf('Vext%d', e); end
    strain_x = nan(n, nE); strain_d = nan(n, nE);
    u1 = nan(n, nE); v1 = u1; u2 = u1; v2 = u1; cmin = nan(n, nE); nval = zeros(n, nE);
    for e = 1:nE
        X1 = mean(squeeze(cx(e,1,:))); X2 = mean(squeeze(cx(e,2,:)));
        Y1 = mean(squeeze(cy(e,1,:))); Y2 = mean(squeeze(cy(e,2,:)));
        L0x = X2 - X1;  L0 = hypot(X2 - X1, Y2 - Y1);
        for k = 1:n
            a = squeeze(DX(k,e,1,:)); b = squeeze(DY(k,e,1,:));
            c = squeeze(DX(k,e,2,:)); d = squeeze(DY(k,e,2,:));
            va = ~isnan(a); vc = ~isnan(c);
            cp = [squeeze(CP(k,e,1,:)); squeeze(CP(k,e,2,:))];
            nval(k,e) = sum(va) + sum(vc);
            cmin(k,e) = min(cp);
            if any(va) && any(vc)
                u1(k,e) = mean(a(va)); v1(k,e) = mean(b(va));
                u2(k,e) = mean(c(vc)); v2(k,e) = mean(d(vc));
                strain_x(k,e) = (u2(k,e) - u1(k,e)) / L0x;
                strain_d(k,e) = hypot(X2 + u2(k,e) - X1 - u1(k,e), Y2 + v2(k,e) - Y1 - v1(k,e)) / L0 - 1;
            end
        end
    end

    % ------------------------------------------------------------ timestamps
    time_s = load_time_s(sample_dir, n);

    % ------------------------------------------------------------ CSV
    hdr = {'image_index', 'time_s'};
    dat = [(1:n)', time_s(:)];
    for e = 1:nE
        hdr = [hdr, strcat([nm{e} '_'], {'strain_x','strain_dist','u1_px','v1_px','u2_px','v2_px','corr_min','n_valid'})]; %#ok<AGROW>
        dat = [dat, strain_x(:,e), strain_d(:,e), u1(:,e), v1(:,e), u2(:,e), v2(:,e), cmin(:,e), nval(:,e)]; %#ok<AGROW>
    end
    csv_path = fullfile(out_dir, [stem '.csv']);
    fid = fopen(csv_path, 'w');
    fprintf(fid, '%s\n', strjoin(hdr, ','));
    fprintf(fid, [repmat('%.10g,', 1, size(dat,2)-1) '%.10g\n'], dat');
    fclose(fid);

    info_path = fullfile(out_dir, [stem '_info.csv']);
    fid = fopen(info_path, 'w');
    fprintf(fid, 'name,x1_px,y1_px,x2_px,y2_px,gauge_px,gauge_mm,px_per_mm,num_subsets,subset_spacing_px,subset_radius_px,search_radius_px,n_frames,sample_dir\n');
    for e = 1:nE
        gpx = mean(squeeze(cx(e,2,:))) - mean(squeeze(cx(e,1,:)));
        fprintf(fid, '%s,%g,%g,%g,%g,%g,%g,%g,%d,%g,%d,%d,%d,"%s"\n', nm{e}, ...
                mean(squeeze(cx(e,1,:))), mean(squeeze(cy(e,1,:))), ...
                mean(squeeze(cx(e,2,:))), mean(squeeze(cy(e,2,:))), ...
                gpx, gpx / o.PxPerMm, o.PxPerMm, m, o.SubsetSpacingPx, r, S, n, sample_dir);
    end
    fclose(fid);

    % ------------------------------------------------------------ report + figure
    if o.Verbose
        fprintf('Saved: %s\n       %s\n', csv_path, info_path);
        for e = 1:nE
            lowc = sum(cmin(:,e) < 0.8);
            fprintf('  %s: peak strain_x = %.4f %% ; min correlation %.3f ; frames with corr<0.8: %d\n', ...
                    nm{e}, 100*max(strain_x(:,e)), min(cmin(:,e)), lowc);
        end
    end
    if o.SaveFigure
        fig = figure('Visible', 'off', 'Position', [100 100 1100 500]);
        subplot(1, 2, 1); imshow(ref, []); hold on;
        for e = 1:nE
            for s = 1:2
                plot(squeeze(cx(e,s,:)), squeeze(cy(e,s,:)), 's', 'MarkerSize', 8, 'LineWidth', 1.5);
            end
            plot([mean(squeeze(cx(e,1,:))) mean(squeeze(cx(e,2,:)))], ...
                 [mean(squeeze(cy(e,1,:))) mean(squeeze(cy(e,2,:)))], '-', 'LineWidth', 1.5);
        end
        title('Reference image + tracked subsets');
        subplot(1, 2, 2); plot(time_s, 100*strain_x, 'LineWidth', 1.4); grid on;
        xlabel('Time (s)'); ylabel('Strain (%)'); title('Virtual extensometer strain_x');
        legend(nm, 'Location', 'best', 'Interpreter', 'none');
        png_path = fullfile(out_dir, [stem '.png']);
        saveas(fig, png_path); close(fig);
        if o.Verbose, fprintf('       %s\n', png_path); end
    end

    out = struct('csv', csv_path, 'info_csv', info_path, 'names', {nm}, 'image_index', (1:n)', ...
                 'time_s', time_s(:), 'strain_x', strain_x, 'strain_dist', strain_d, ...
                 'u1', u1, 'v1', v1, 'u2', u2, 'v2', v2, 'corr_min', cmin, 'n_valid', nval, ...
                 'points', P);
end

% =====================================================================
% local functions
% =====================================================================
function [dx, dy, cp] = track_one(Tp, img, x0, y0, r, S, dprev)
% Displacement of template Tp (cut from the reference at x0,y0) in img.
    dx = NaN; dy = NaN; cp = NaN;
    [H, W] = size(img);
    ccx = x0 + round(dprev(1));  ccy = y0 + round(dprev(2));
    xa = ccx - r - S;  xb = ccx + r + S;  ya = ccy - r - S;  yb = ccy + r + S;
    if xa < 1 || ya < 1 || xb > W || yb > H, return; end
    win = img(ya:yb, xa:xb);
    c = normxcorr2(Tp, win);
    tH = size(Tp, 1);  tW = size(Tp, 2);
    sub = c(tH:size(win,1), tW:size(win,2));        % full-overlap part
    [pk, idx] = max(sub(:));
    if isnan(pk), return; end
    [py, px] = ind2sub(size(sub), idx);
    sx = 0; sy = 0;
    if px > 1 && px < size(sub, 2)
        cl = sub(py, px-1); cc = sub(py, px); cr = sub(py, px+1);
        den = cl - 2*cc + cr;
        if den < 0, sx = 0.5*(cl - cr)/den; end
    end
    if py > 1 && py < size(sub, 1)
        cu = sub(py-1, px); cc = sub(py, px); cd = sub(py+1, px);
        den = cu - 2*cc + cd;
        if den < 0, sy = 0.5*(cu - cd)/den; end
    end
    dx = (xa + px - 1 + sx) - (x0 - r);
    dy = (ya + py - 1 + sy) - (y0 - r);
    cp = pk;
end

function I = read_gray(path)
    I = imread(path);
    if ndims(I) > 2, I = mean(double(I), 3); end
    I = double(I);
end

function names = natural_sort(names)
    key = zeros(numel(names), 1);
    for i = 1:numel(names)
        tok = regexp(names{i}, '\d+', 'match');
        if isempty(tok), key(i) = 0; else, key(i) = str2double(tok{end}); end
    end
    [~, ix] = sortrows([key (1:numel(names))']);
    names = names(ix);
end

function t = load_time_s(sample_dir, n)
    t = (0:n-1)';
    csv = fullfile(sample_dir, 'timestamps.csv');
    try
        if exist(csv, 'file')
            T = readmatrix(csv);
            if size(T, 2) >= 2, T = T(:, end); end
            T = T(:);
            if numel(T) >= n
                t = T(1:n) - T(1);
                return;
            end
        end
    catch
    end
    warning('ncorr_virtual_extensometer: no usable timestamps.csv; time_s is the frame index.');
end

function P = pick_points(ref, mode, L_px)
    f = figure('Name', 'Virtual extensometer: click on the reference image', 'NumberTitle', 'off');
    imshow(ref, []);
    P = [];
    if strcmpi(mode, 'center')
        title(sprintf('Click the CENTER of the extensometer (gauge = %.0f px). Press Enter after the last one.', L_px));
        [x, y] = ginput;
        if ~isempty(x), P = [x(:) - L_px/2, y(:), x(:) + L_px/2, y(:)]; end
    else
        title('Click edge 1 then edge 2 of each extensometer. Press Enter when done.');
        [x, y] = ginput;
        k = floor(numel(x)/2);
        if k > 0, P = [x(1:2:2*k), y(1:2:2*k), x(2:2:2*k), y(2:2:2*k)]; end
    end
    close(f);
end
