function ncorr_view_results(src, px_per_mm)
% NCORR_VIEW_RESULTS  Interactive viewer for ncorr_batch_run *_results.mat files.
%
%   ncorr_view_results                  - pick a results file with a dialog
%   ncorr_view_results('path.mat')      - open a results file
%   ncorr_view_results(results_struct)  - view a results struct already loaded
%   ncorr_view_results(src, px_per_mm)  - set image scale (default 49.7 px/mm,
%                                         from the checkerboard calibration, 1080p)
%
% Features
%   * Frame slider through displacement / strain maps over the reference image
%     (exx, eyy, exy, max/min principal strain, u, v, corrcoef)
%   * Probe mode: click the map to add a probe point (optionally averaged over
%     a 3x3 ... 15x15 window of grid points). Time series of the selected field
%     is plotted for every probe.
%   * Gage rectangle: drag a rectangle over the gage section; the spatial
%     mean (and std) over valid points is tracked over time.
%   * Virtual extensometer: click a center point; two edges are placed
%     gauge_mm apart along x (e.g. 4 mm to mimic a physical extensometer).
%     Strain = (mean u at right edge - mean u at left edge) / reference
%     separation, with u averaged over all valid points across the specimen
%     at each edge column. This is ENGINEERING strain (shown when field = exx).
%   * Export: CSV of all probes/gage (all fields) + a probe-location CSV,
%     or send to the base workspace as 'probe_data'.
%
% Conventions
%   * Frame k of displacements/strains compares image k+1 to reference image 1.
%     CSV column 'image_index' is k+1; 'time_s' is timestamps(k+1)-timestamps(1).
%   * Strains are Green-Lagrangian components (exx, eyy, exy tensor shear).
%   * Maps live on the DIC grid (spacing+1 px apart); coordinates shown/exported
%     are in reference-image pixels (x = column, y = row, origin at 1,1).

    if nargin < 2 || isempty(px_per_mm), px_per_mm = 49.7; end

    % ---------------------------------------------------------------- load
    if nargin < 1 || isempty(src)
        [f, p] = uigetfile('*_results.mat', 'Select a results file');
        if isequal(f, 0), return; end
        src = fullfile(p, f);
    end
    if ischar(src) || isstring(src)
        src = char(src);
        S = load(src, 'results');
        R = S.results;
        [src_dir, src_base] = fileparts(src);
        export_base = fullfile(src_dir, src_base);
    else
        R = src;
        export_base = fullfile(pwd, 'ncorr_view');
    end

    nF = numel(R.displacements);
    has_strain = isstruct(R.strains) && isfield(R.strains, 'plot_exx_ref_formatted') && ...
                 numel(R.strains) >= 1 && ~isempty(R.strains(1).plot_exx_ref_formatted);
    if has_strain, nF = min(nF, numel(R.strains)); end

    [nr, nc] = size(R.displacements(1).plot_u);
    spacing = R.dispinfo.spacing;
    if isempty(spacing), spacing = 0; end
    step = spacing + 1;
    units = R.dispinfo.units;
    if isempty(units), units = 'pixels'; end

    ts_all = fix_frame_index_timestamps(R, R.timestamps(:));
    if numel(ts_all) >= nF + 1
        t = ts_all(2:nF+1) - ts_all(1);
    else
        t = (1:nF)';
    end

    if has_strain
        keys  = {'exx','eyy','exy','e1','e2','u','v','cc'};
        names = {'exx (Green-Lagrange)','eyy (Green-Lagrange)','exy (Green-Lagrange)', ...
                 'e1 (max principal)','e2 (min principal)', ...
                 ['u (' units ')'],['v (' units ')'],'corrcoef'};
    else
        keys  = {'u','v','cc'};
        names = {['u (' units ')'],['v (' units ')'],'corrcoef'};
        warndlg('No strain fields found in this results file; only displacements are shown.');
    end
    sfield = struct('exx','plot_exx_ref_formatted','eyy','plot_eyy_ref_formatted', ...
                    'exy','plot_exy_ref_formatted');

    % background reference image
    bg = load_reference_image(R, nr, nc, step);
    [H, W] = size(bg(:,:,1));
    xdata = [1, (nc-1)*step + 1];
    ydata = [1, (nr-1)*step + 1];

    % ---------------------------------------------------------------- state
    items  = {};      % probes / gage; each a struct
    n_probe_counter = 0;
    n_vext_counter  = 0;
    cur_k  = 1;
    half_opts = [0 1 2 4 7];
    colors = lines(7);
    hVL = [];

    % ---------------------------------------------------------------- UI
    fig = figure('NumberTitle', 'off', 'Units', 'normalized');
    set(fig, 'Position', [0.05 0.07 0.90 0.85]);
    set(fig, 'Color', [0.94 0.94 0.94]);
    set(fig, 'Name', ['ncorr results viewer - ' sample_label(R)]);
    axM = axes('Parent', fig, 'Units', 'normalized', 'Position', [0.04 0.40 0.62 0.56]);
    axT = axes('Parent', fig, 'Units', 'normalized', 'Position', [0.07 0.08 0.59 0.24]);
    hP  = uipanel('Parent', fig, 'Units', 'normalized', 'Position', [0.69 0.03 0.30 0.94], 'Title', 'Controls');

    mk = @(style, pos, str, cb) uicontrol(hP, 'Style', style, 'Units', 'normalized', ...
                                          'Position', pos, 'String', str, 'Callback', cb);
    mk('text', [0.04 0.945 0.92 0.03], 'Field', []);
    hField = mk('popupmenu', [0.04 0.915 0.92 0.035], names, @(~,~) on_field());
    mk('text', [0.04 0.875 0.92 0.03], 'Probe averaging window (grid points)', []);
    hSize = mk('popupmenu', [0.04 0.845 0.92 0.035], {'1 point','3 x 3','5 x 5','9 x 9','15 x 15'}, []);
    hFrameTxt = mk('text', [0.04 0.805 0.92 0.03], '', []);
    hSlide = mk('slider', [0.04 0.775 0.92 0.03], '', @(~,~) on_slider());
    set(hSlide, 'Min', 1, 'Max', max(nF, 2), 'Value', 1, 'SliderStep', [1/max(nF-1,1), min(10/max(nF-1,1),1)]);
    if nF == 1, set(hSlide, 'Enable', 'off'); end
    try
        addlistener(hSlide, 'ContinuousValueChange', @(~,~) on_slider());
    catch
    end
    hFix  = mk('checkbox', [0.04 0.735 0.92 0.03], 'Fixed color limits (use boxes)', @(~,~) refresh_map());
    hCmin = mk('edit', [0.04 0.700 0.44 0.032], '', @(~,~) on_limit_edit());
    hCmax = mk('edit', [0.52 0.700 0.44 0.032], '', @(~,~) on_limit_edit());
    hMode = mk('togglebutton', [0.04 0.650 0.92 0.04], 'Probe mode: click map to add point', []);
    set(hMode, 'Value', 1);
    mk('pushbutton', [0.04 0.600 0.92 0.04], 'Draw gage rectangle (mean over region)', @(~,~) on_gage());
    mk('pushbutton', [0.04 0.555 0.92 0.04], 'Virtual extensometer (click center)', @(~,~) on_vext());
    mk('pushbutton', [0.04 0.510 0.44 0.04], 'Delete selected', @(~,~) on_delete());
    mk('pushbutton', [0.52 0.510 0.44 0.04], 'Clear all', @(~,~) on_clear());
    mk('text', [0.04 0.475 0.44 0.025], 'Scale (px/mm)', []);
    mk('text', [0.52 0.475 0.44 0.025], 'Ext. gauge (mm)', []);
    hScale = mk('edit', [0.04 0.440 0.44 0.032], sprintf('%.4g', px_per_mm), []);
    hGauge = mk('edit', [0.52 0.440 0.44 0.032], '4', []);
    hList = uicontrol(hP, 'Style', 'listbox', 'Units', 'normalized', 'Position', [0.04 0.215 0.92 0.215], ...
                      'String', {}, 'Max', 1, 'Min', 1, 'Value', []);
    mk('pushbutton', [0.04 0.160 0.92 0.045], 'Export time series CSV...', @(~,~) on_export());
    mk('pushbutton', [0.04 0.108 0.92 0.045], 'Send to workspace (probe_data)', @(~,~) on_workspace());
    mk('text', [0.04 0.005 0.92 0.095], sprintf(['Grid: %d x %d points, spacing %d px.\n' ...
        'Frame k = image k+1 vs reference image 1.\n' ...
        'Turn probe mode off to zoom/pan the map.'], nr, nc, spacing), []);
    set(findobj(hP, 'Style', 'text'), 'HorizontalAlignment', 'left');

    % map axes: background + overlay
    hold(axM, 'on');
    image(axM, [1 W], [1 H], bg, 'HitTest', 'on', 'ButtonDownFcn', @on_map_click);
    hOv = image(axM, xdata, ydata, nan(nr, nc), 'CDataMapping', 'scaled', ...
                'AlphaData', zeros(nr, nc), 'HitTest', 'on', 'ButtonDownFcn', @on_map_click);
    axis(axM, 'image'); set(axM, 'YDir', 'reverse', 'Box', 'on');
    set(axM, 'ButtonDownFcn', @on_map_click);
    xlim(axM, [1 W]); ylim(axM, [1 H]);
    colormap(axM, parula(256));
    hCB = colorbar(axM);
    xlabel(axM, 'x (px)'); ylabel(axM, 'y (px)');

    grid(axT, 'on'); box(axT, 'on');
    xlabel(axT, 'Time (s)');

    refresh_map();
    refresh_ts();

    % =================================================================
    % callbacks
    % =================================================================
    function on_slider()
        k = round(get(hSlide, 'Value'));
        k = min(max(k, 1), nF);
        if k ~= cur_k
            cur_k = k;
            refresh_map();
        end
    end

    function on_field()
        refresh_map();
        refresh_ts();
    end

    function on_limit_edit()
        set(hFix, 'Value', 1);
        refresh_map();
    end

    function on_map_click(~, ~)
        if ~get(hMode, 'Value'), return; end
        cp = get(axM, 'CurrentPoint');
        x = cp(1,1); y = cp(1,2);
        if x < 1 || x > W || y < 1 || y > H, return; end
        col = min(max(round((x - 1)/step) + 1, 1), nc);
        row = min(max(round((y - 1)/step) + 1, 1), nr);
        h = half_opts(get(hSize, 'Value'));
        n_probe_counter = n_probe_counter + 1;
        it = make_item(sprintf('P%d', n_probe_counter), false, ...
                       max(1,row-h):min(nr,row+h), max(1,col-h):min(nc,col+h), row, col);
        items{end+1} = it;
        refresh_list(); redraw_markers(); refresh_ts();
        set(hList, 'Value', numel(items));
    end

    function on_gage()
        figure(fig);
        set(hMode, 'Value', 0);
        title(axM, 'Drag a rectangle over the gage section...');
        rect = getrect(axM);
        if rect(3) < 1 || rect(4) < 1
            refresh_map(); return;
        end
        c1 = min(max(round((rect(1) - 1)/step) + 1, 1), nc);
        c2 = min(max(round((rect(1) + rect(3) - 1)/step) + 1, 1), nc);
        r1 = min(max(round((rect(2) - 1)/step) + 1, 1), nr);
        r2 = min(max(round((rect(2) + rect(4) - 1)/step) + 1, 1), nr);
        rows = min(r1,r2):max(r1,r2);
        cols = min(c1,c2):max(c1,c2);
        it = make_item('Gage', true, rows, cols, round(mean(rows)), round(mean(cols)));
        % replace existing gage
        for q = numel(items):-1:1
            if items{q}.isgage, items(q) = []; end
        end
        items{end+1} = it;
        set(hMode, 'Value', 1);
        refresh_list(); redraw_markers(); refresh_ts(); refresh_map();
        set(hList, 'Value', numel(items));
    end

    function on_vext()
        pxmm = str2double(get(hScale, 'String'));
        Lmm  = str2double(get(hGauge, 'String'));
        if ~(isfinite(pxmm) && pxmm > 0 && isfinite(Lmm) && Lmm > 0)
            warndlg('Enter a positive scale (px/mm) and extensometer gauge length (mm).'); return;
        end
        figure(fig);
        set(hMode, 'Value', 0);
        title(axM, 'Click the CENTER of the virtual extensometer...');
        [x, y] = ginput(1);
        set(hMode, 'Value', 1);
        if isempty(x) || x < 1 || x > W || y < 1 || y > H
            refresh_map(); return;
        end
        col = min(max(round((x - 1)/step) + 1, 1), nc);
        row = min(max(round((y - 1)/step) + 1, 1), nr);
        Lg  = Lmm * pxmm / step;                 % gauge length in grid columns
        span = max(1, round(Lg));
        c1 = col - floor(span/2);
        c2 = c1 + span;
        if c1 < 1 || c2 > nc
            warndlg('Extensometer would extend past the image; click closer to the center.');
            refresh_map(); return;
        end
        n_vext_counter = n_vext_counter + 1;
        it = make_item(sprintf('Vext%d', n_vext_counter), false, row:row, c1:c2, row, round((c1+c2)/2));
        it.kind  = 'vext';
        it.c1    = c1;
        it.c2    = c2;
        it.L_mm  = (c2 - c1) * step / pxmm;      % actual gauge length after grid snapping
        items{end+1} = it;
        refresh_list(); redraw_markers(); refresh_ts(); refresh_map();
        set(hList, 'Value', numel(items));
        if abs(it.L_mm - Lmm) > 0.05
            fprintf('Virtual extensometer %s: requested %.3f mm, grid-snapped to %.3f mm.\n', it.name, Lmm, it.L_mm);
        end
    end

    function on_delete()
        if isempty(items), return; end
        i = get(hList, 'Value');
        if i >= 1 && i <= numel(items)
            items(i) = [];
        end
        refresh_list(); redraw_markers(); refresh_ts();
        if ~isempty(items)
            set(hList, 'Value', max(1, min(i, numel(items))));
        end
    end

    function on_clear()
        items = {};
        refresh_list(); redraw_markers(); refresh_ts();
    end

    function on_export()
        if isempty(items)
            warndlg('Add at least one probe or a gage rectangle first.'); return;
        end
        [f, p] = uiputfile('*.csv', 'Export time series', [export_base '_probes.csv']);
        if isequal(f, 0), return; end
        out_csv = fullfile(p, f);
        wb = waitbar_safe('Computing time series...');
        % assemble columns
        hdr = {'image_index', 'time_s'};
        dat = [(2:nF+1)', t(:)];
        for i = 1:numel(items)
            it = items{i};
            qkeys = keys;
            if strcmp(it.kind, 'vext'), qkeys = {'exx'}; end
            for q = 1:numel(qkeys)
                ts = get_ts(i, qkeys{q});
                hdr{end+1} = [it.name '_' qkeys{q}];       %#ok<AGROW>
                dat = [dat, ts.mean(:)];                    %#ok<AGROW>
            end
            if has_strain && ~strcmp(it.kind, 'vext')
                ts = get_ts(i, 'exx');
                hdr{end+1} = [it.name '_exx_std'];          %#ok<AGROW>
                dat = [dat, ts.std(:)];                     %#ok<AGROW>
                hdr{end+1} = [it.name '_n_valid'];          %#ok<AGROW>
                dat = [dat, ts.n(:)];                       %#ok<AGROW>
            end
        end
        fid = fopen(out_csv, 'w');
        fprintf(fid, '%s\n', strjoin(hdr, ','));
        fmt = [repmat('%.10g,', 1, size(dat,2)-1) '%.10g\n'];
        fprintf(fid, fmt, dat');
        fclose(fid);
        % probe info
        info_csv = [out_csv(1:end-4) '_locations.csv'];
        fid = fopen(info_csv, 'w');
        fprintf(fid, 'name,type,center_x_px,center_y_px,grid_row,grid_col,row_start,row_end,col_start,col_end,x_start_px,x_end_px,y_start_px,y_end_px,u_v_units,gauge_mm,px_per_mm\n');
        for i = 1:numel(items)
            it = items{i};
            ty = it.kind;
            gm = NaN; if strcmp(ty, 'vext'), gm = it.L_mm; end
            fprintf(fid, '%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%g,%g\n', it.name, ty, it.x, it.y, ...
                    it.row, it.col, it.rows(1), it.rows(end), it.cols(1), it.cols(end), ...
                    (it.cols(1)-1)*step+1, (it.cols(end)-1)*step+1, ...
                    (it.rows(1)-1)*step+1, (it.rows(end)-1)*step+1, units, gm, px_per_mm);
        end
        fclose(fid);
        if ~isempty(wb) && isgraphics(wb), delete(wb); end
        msgbox(sprintf('Saved:\n%s\n%s', out_csv, info_csv), 'Export complete');
    end

    function on_workspace()
        if isempty(items)
            warndlg('Add at least one probe or a gage rectangle first.'); return;
        end
        wb = waitbar_safe('Computing time series...');
        pd = struct('image_index', (2:nF+1)', 'time_s', t(:), 'units_uv', units, 'items', struct());
        for i = 1:numel(items)
            it = items{i};
            s = struct('x_px', it.x, 'y_px', it.y, 'rows', it.rows, 'cols', it.cols);
            qkeys = keys;
            if strcmp(it.kind, 'vext'), qkeys = {'exx'}; s.gauge_mm = it.L_mm; end
            for q = 1:numel(qkeys)
                ts = get_ts(i, qkeys{q});
                s.(qkeys{q}) = ts.mean(:);
                s.([qkeys{q} '_std']) = ts.std(:);
            end
            pd.items.(matlab.lang.makeValidName(it.name)) = s;
        end
        assignin('base', 'probe_data', pd);
        if ~isempty(wb) && isgraphics(wb), delete(wb); end
        msgbox('Time series sent to base workspace as ''probe_data''.', 'Done');
    end

    % =================================================================
    % drawing
    % =================================================================
    function refresh_map()
        key = keys{get(hField, 'Value')};
        M = get_block(key, cur_k, ':', ':');
        set(hOv, 'CData', M, 'AlphaData', 0.85 * double(~isnan(M)));
        lim = current_limits(M);
        set(axM, 'CLim', lim);
        set(hCmin, 'String', sprintf('%.4g', lim(1)));
        set(hCmax, 'String', sprintf('%.4g', lim(2)));
        try
            hCB.Label.String = names{get(hField, 'Value')};
            hCB.Label.Interpreter = 'none';
        catch
        end
        set(hFrameTxt, 'String', sprintf('Frame %d / %d   (image %d)   t = %.3f s', cur_k, nF, cur_k + 1, t(cur_k)));
        set(hSlide, 'Value', cur_k);
        title(axM, sprintf('%s   -   %s   -   t = %.3f s', sample_label(R), names{get(hField,'Value')}, t(cur_k)), ...
              'Interpreter', 'none');
        if ~isempty(hVL) && isgraphics(hVL)
            set(hVL, 'XData', [t(cur_k) t(cur_k)]);
        end
    end

    function lim = current_limits(M)
        lim = [];
        if get(hFix, 'Value')
            a = str2double(get(hCmin, 'String'));
            b = str2double(get(hCmax, 'String'));
            if isfinite(a) && isfinite(b) && b > a
                lim = [a b]; return;
            end
        end
        v = M(~isnan(M));
        if isempty(v)
            lim = [0 1]; return;
        end
        v = sort(v(:));
        n = numel(v);
        lo = v(max(1, round(0.02*n)));
        hi = v(min(n, max(1, round(0.98*n))));
        if hi <= lo
            d = max(abs(lo)*0.1, 1e-6);
            lo = lo - d; hi = hi + d;
        end
        lim = [lo hi];
    end

    function refresh_ts()
        key = keys{get(hField, 'Value')};
        delete(allchild(axT));
        hold(axT, 'on');
        hl = gobjects(0);
        nm = {};
        for i = 1:numel(items)
            ts = get_ts(i, key);
            c = item_color(i);
            ls = '-'; if items{i}.isgage, ls = '--'; end
            hl(end+1) = plot(axT, t, ts.mean, ls, 'Color', c, 'LineWidth', 1.4); %#ok<AGROW>
            nm{end+1} = items{i}.name;                                           %#ok<AGROW>
        end
        yl = [0 1];
        if ~isempty(items) && numel(t) > 1
            axis(axT, 'tight');
            yl = get(axT, 'YLim');
            if yl(2) <= yl(1), yl = yl + [-1 1]*1e-6; end
            pad = 0.05*(yl(2)-yl(1));
            yl = yl + [-pad pad];
            set(axT, 'YLim', yl);
        else
            set(axT, 'XLim', [min(t) max(t)+eps], 'YLim', yl);
        end
        hVL = plot(axT, [t(cur_k) t(cur_k)], yl, 'k:', 'LineWidth', 1);
        set(hVL, 'HandleVisibility', 'off');
        if ~isempty(hl)
            legend(axT, hl, nm, 'Location', 'best', 'Interpreter', 'none');
        else
            legend(axT, 'off');
        end
        ylabel(axT, names{get(hField, 'Value')}, 'Interpreter', 'none');
        xlabel(axT, 'Time (s)');
        grid(axT, 'on');
    end

    function redraw_markers()
        delete(findobj(axM, 'Tag', 'probe_marker'));
        for i = 1:numel(items)
            it = items{i};
            c = item_color(i);
            x0 = (it.cols(1) - 1)*step + 1 - step/2;
            y0 = (it.rows(1) - 1)*step + 1 - step/2;
            w  = (numel(it.cols))*step;
            h  = (numel(it.rows))*step;
            if strcmp(it.kind, 'vext')
                xa = (it.c1 - 1)*step + 1; xb = (it.c2 - 1)*step + 1; yy = it.y;
                plot(axM, [xa xb], [yy yy], '-', 'Color', c, 'LineWidth', 2, ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
                plot(axM, [xa xa], [yy-25 yy+25], '-', 'Color', c, 'LineWidth', 2, ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
                plot(axM, [xb xb], [yy-25 yy+25], '-', 'Color', c, 'LineWidth', 2, ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
                text(axM, (xa+xb)/2, yy - 32, sprintf('%s (%.2f mm)', it.name, it.L_mm), 'Color', c, ...
                     'FontWeight', 'bold', 'HorizontalAlignment', 'center', ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
            elseif it.isgage
                rectangle(axM, 'Position', [x0 y0 w h], 'EdgeColor', c, 'LineStyle', '--', ...
                          'LineWidth', 1.6, 'Tag', 'probe_marker', 'HitTest', 'off');
                text(axM, x0 + 3, y0 + 3, it.name, 'Color', c, 'FontWeight', 'bold', ...
                     'VerticalAlignment', 'top', 'Tag', 'probe_marker', 'HitTest', 'off');
            else
                plot(axM, it.x, it.y, '+', 'Color', c, 'MarkerSize', 10, 'LineWidth', 1.8, ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
                if numel(it.rows) > 1 || numel(it.cols) > 1
                    rectangle(axM, 'Position', [x0 y0 w h], 'EdgeColor', c, 'LineWidth', 1.2, ...
                              'Tag', 'probe_marker', 'HitTest', 'off');
                end
                text(axM, it.x + 6, it.y - 6, it.name, 'Color', c, 'FontWeight', 'bold', ...
                     'Tag', 'probe_marker', 'HitTest', 'off');
            end
        end
    end

    function refresh_list()
        s = cell(1, numel(items));
        for i = 1:numel(items)
            it = items{i};
            if strcmp(it.kind, 'vext')
                s{i} = sprintf('%s  (x=%d, y=%d, gauge %.2f mm)', it.name, it.x, it.y, it.L_mm);
            else
                s{i} = sprintf('%s  (x=%d, y=%d, %dx%d pts)', it.name, it.x, it.y, ...
                               numel(it.rows), numel(it.cols));
            end
        end
        if isempty(items)
            set(hList, 'String', {}, 'Value', []);
        else
            set(hList, 'String', s, 'Value', max(1, min(get(hList,'Value'), numel(items))));
        end
    end

    function c = item_color(i)
        if items{i}.isgage
            c = [0 0 0];
        else
            c = colors(mod(i-1, size(colors,1)) + 1, :);
        end
    end

    % =================================================================
    % data access
    % =================================================================
    function it = make_item(name, isgage, rows, cols, row, col)
        kind = 'probe'; if isgage, kind = 'gage'; end
        it = struct('name', name, 'isgage', isgage, 'kind', kind, 'rows', rows, 'cols', cols, ...
                    'row', row, 'col', col, ...
                    'x', (col-1)*step + 1, 'y', (row-1)*step + 1, 'cache', struct());
    end

    function ts = get_ts(i, key)
        it = items{i};
        if strcmp(it.kind, 'vext')
            if ~isfield(it.cache, 'exx')
                [e, nn] = vext_series(it);
                it.cache.exx = struct('mean', e, 'std', nan(nF,1), 'n', nn);
                items{i} = it;
            end
            if strcmp(key, 'exx')
                ts = items{i}.cache.exx;
            else
                ts = struct('mean', nan(nF,1), 'std', nan(nF,1), 'n', zeros(nF,1));
            end
            return;
        end
        if ~isfield(it.cache, key)
            [m, s, n] = region_stat(key, it.rows, it.cols);
            it.cache.(key) = struct('mean', m, 'std', s, 'n', n);
            items{i} = it;
        end
        ts = items{i}.cache.(key);
    end

    function [e, nn] = vext_series(it)
        % Engineering strain from the relative displacement of two edge columns.
        e = nan(nF, 1); nn = zeros(nF, 1);
        pu = R.dispinfo.pixtounits;
        if isempty(pu), pu = 1; end
        L0 = (it.c2 - it.c1) * step * pu;         % reference separation, in u units
        hw = 1;                                    % average +/- 1 grid column at each edge
        for k = 1:nF
            U  = R.displacements(k).plot_u;
            Vm = logical(R.displacements(k).plot_validpoints);
            [u1, n1] = edge_mean(U, Vm, it.c1, hw);
            [u2, n2] = edge_mean(U, Vm, it.c2, hw);
            nn(k) = min(n1, n2);
            if n1 > 0 && n2 > 0
                e(k) = (u2 - u1) / L0;
            end
        end
    end

    function [m, n] = edge_mean(U, Vm, c, hw)
        cols = max(1, c-hw):min(nc, c+hw);
        B = U(:, cols); Mk = Vm(:, cols) & ~isnan(B);
        v = B(Mk);
        n = numel(v);
        if n > 0, m = mean(v); else, m = NaN; end
    end

    function [m, s, n] = region_stat(key, rows, cols)
        m = nan(nF, 1); s = nan(nF, 1); n = zeros(nF, 1);
        for k = 1:nF
            B = get_block(key, k, rows, cols);
            v = B(~isnan(B));
            n(k) = numel(v);
            if n(k) > 0, m(k) = mean(v); end
            if n(k) > 1, s(k) = std(v); end
        end
    end

    function B = get_block(key, k, rows, cols)
        switch key
            case 'u'
                B = R.displacements(k).plot_u(rows, cols);
                mkm = R.displacements(k).plot_validpoints(rows, cols);
            case 'v'
                B = R.displacements(k).plot_v(rows, cols);
                mkm = R.displacements(k).plot_validpoints(rows, cols);
            case 'cc'
                B = R.displacements(k).plot_corrcoef(rows, cols);
                mkm = R.displacements(k).plot_validpoints(rows, cols);
            case {'exx', 'eyy', 'exy'}
                B = R.strains(k).(sfield.(key))(rows, cols);
                mkm = R.strains(k).plot_validpoints(rows, cols);
            case {'e1', 'e2'}
                a = double(R.strains(k).plot_exx_ref_formatted(rows, cols));
                b = double(R.strains(k).plot_eyy_ref_formatted(rows, cols));
                c = double(R.strains(k).plot_exy_ref_formatted(rows, cols));
                avg = (a + b)/2;
                rad = sqrt(((a - b)/2).^2 + c.^2);
                if strcmp(key, 'e1'), B = avg + rad; else, B = avg - rad; end
                mkm = R.strains(k).plot_validpoints(rows, cols);
            otherwise
                error('Unknown field key: %s', key);
        end
        B = double(B);
        B(~logical(mkm)) = NaN;
    end
end

% =====================================================================
% local helpers
% =====================================================================
function s = sample_label(R)
    s = 'results';
    try
        if isfield(R, 'metadata') && isfield(R.metadata, 'sample_name')
            s = char(join(string(R.metadata.sample_name(:)'), ' '));
        end
    catch
    end
end

function h = waitbar_safe(msg)
    % Plain message window (no waitbar so it can't collide with the batch stub).
    try
        h = msgbox(msg, 'Working', 'help');
        drawnow;
    catch
        h = [];
    end
end

function bg = load_reference_image(R, nr, nc, step)
% RGB double image [0,1] of the reference frame; falls back to the ROI mask.
    bg = [];
    try
        d = R.metadata.sample_dir;
        if exist(d, 'dir')
            f = [dir(fullfile(d, '*.tif')); dir(fullfile(d, '*.tiff'))];
            if ~isempty(f)
                [~, ix] = sort({f.name});
                I = imread(fullfile(d, f(ix(1)).name));
                if size(I, 3) > 1, I = mean(double(I), 3); end
                I = double(I);
                lo = min(I(:)); hi = max(I(:));
                if hi > lo, I = (I - lo)/(hi - lo); else, I = zeros(size(I)); end
                bg = repmat(I, [1 1 3]);
            end
        end
    catch
        bg = [];
    end
    if isempty(bg)
        try
            m = double(R.metadata.roi_mask);
            bg = repmat(0.25 + 0.4*m, [1 1 3]);
        catch
            bg = zeros((nr-1)*step + 1, (nc-1)*step + 1, 3);
        end
    end
end

function ts = fix_frame_index_timestamps(R, ts)
% Older results stored the frame_index column of timestamps.csv instead of
% time_s. If timestamps are exactly 0..n-1 and a two-column timestamps.csv sits
% next to the images, reload time_s from it.
    try
        n = numel(ts);
        if isequal(ts(:), (0:n-1)')
            T = readmatrix(fullfile(R.metadata.sample_dir, 'timestamps.csv'));
            if size(T,2) >= 2 && size(T,1) >= n
                ts = T(1:n, end);
                ts = ts(:);
            end
        end
    catch
    end
end
