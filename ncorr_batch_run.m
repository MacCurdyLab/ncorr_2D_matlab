function batch_results = ncorr_batch_run(batch_config_path, sample_dirs, output_dir, options)
% NCORR_BATCH_RUN  Headless DIC analysis for a batch of samples.
%
% Loads the configuration saved by ncorr_batch_setup, then processes each
% sample directory automatically: auto-segments the ROI, translates the
% seed positions, calls ncorr_alg_dicanalysis with params_init populated
% (no GUI opens), runs format-displacements and strain analysis, and saves
% a results.mat per sample augmented with timestamps and metadata.
%
% Usage
%   batch_results = ncorr_batch_run(batch_config_path, sample_dirs, output_dir);
%   batch_results = ncorr_batch_run(batch_config_path, sample_dirs, output_dir, options);
%
%   % Select config file interactively if path is empty:
%   batch_results = ncorr_batch_run([], sample_dirs, output_dir);
%
% Inputs
%   batch_config_path - Full path to batch_config.mat (from ncorr_batch_setup).
%                       Pass [] to open a file picker.
%   sample_dirs       - Cell array of folder paths, each containing TIFF frames.
%                       Pass [] to open a multi-folder picker.
%   output_dir        - Folder where per-sample results.mat files are written.
%                       Pass [] to open a folder picker.
%   options           - (optional) struct:
%     .subset         Integer vector; run only these sample indices.
%     .dry_run        logical (default false); validate inputs without DIC.
%     .verbose        logical (default false); extra console diagnostics.
%     .roi_params     struct passed to ncorr_auto_roi (blur_sigma etc.).
%                     show_preview defaults to FALSE for batch runs.
%     .save_roi_fig   logical (default false); save PNG of each ROI overlay.
%     .strain_radius  Override strain radius from batch_config (integer).
%
% Output
%   batch_results - struct array, one entry per sample:
%     .sample_name   char
%     .sample_dir    char
%     .output_path   char   (path to results.mat, or '' if failed)
%     .status        char   ('success' | 'failed' | 'skipped')
%     .message       char
%     .elapsed_s     double
%
% See also ncorr_batch_setup, ncorr_auto_roi, ncorr_seed_transform

    if nargin < 4 || isempty(options), options = struct(); end
    if ~isfield(options,'subset'),       options.subset       = [];    end
    if ~isfield(options,'dry_run'),      options.dry_run      = false; end
    if ~isfield(options,'verbose'),      options.verbose      = false; end
    if ~isfield(options,'roi_params'),   options.roi_params   = struct(); end
    if ~isfield(options,'save_roi_fig'), options.save_roi_fig = false; end
    if ~isfield(options,'strain_radius'),options.strain_radius= [];    end

    if ~isfield(options.roi_params,'show_preview')
        options.roi_params.show_preview = false;
    end

    % Load batch_config
    if isempty(batch_config_path)
        [fn, fp] = uigetfile('*.mat','Select batch_config.mat');
        if fn == 0, error('ncorr_batch_run: No config file selected.'); end
        batch_config_path = fullfile(fp, fn);
    end
    cfg_data = load(batch_config_path, 'batch_config');
    cfg = cfg_data.batch_config;
    fprintf('Loaded batch_config from: %s\n', batch_config_path);
    fprintf('  Created: %s  |  Setup sample: %s\n\n', cfg.created_at, cfg.setup_sample);

    if ~isempty(options.strain_radius)
        cfg.strain_radius = options.strain_radius;
    end
    if isempty(cfg.strain_radius)
        warning('ncorr_batch_run: strain_radius not set - strain analysis will be skipped.');
    end

    % Select sample directories
    if isempty(sample_dirs)
        sample_dirs = {};
        fprintf('Select sample directories one at a time. Cancel when done.\n');
        while true
            d = uigetdir(pwd, sprintf('Select sample folder #%d (Cancel to finish)', ...
                                      numel(sample_dirs)+1));
            if d == 0, break; end
            sample_dirs{end+1} = d; %#ok<AGROW>
        end
    end
    if isempty(sample_dirs)
        error('ncorr_batch_run: No sample directories provided.');
    end

    % Select output directory
    if isempty(output_dir)
        output_dir = uigetdir(pwd, 'Select output directory for results files');
        if output_dir == 0, error('ncorr_batch_run: No output directory selected.'); end
    end
    if ~exist(output_dir,'dir'), mkdir(output_dir); end

    % Apply subset selection
    total_samples = numel(sample_dirs);
    if ~isempty(options.subset)
        idx_run = options.subset(options.subset >= 1 & options.subset <= total_samples);
        fprintf('Subset mode: running samples %s of %d total.\n', mat2str(idx_run), total_samples);
    else
        idx_run = 1:total_samples;
    end

    % Pre-allocate results
    batch_results = struct('sample_name',cell(numel(idx_run),1), ...
                           'sample_dir',cell(numel(idx_run),1), ...
                           'output_path',cell(numel(idx_run),1), ...
                           'status',cell(numel(idx_run),1), ...
                           'message',cell(numel(idx_run),1), ...
                           'elapsed_s',cell(numel(idx_run),1));

    failed_log_path = fullfile(output_dir, 'failed_samples.txt');
    fid_log = fopen(failed_log_path, 'a');

    % ── Waitbar suppression via path-injected stub ─────────────────────────────
    % ncorr MEX files (ncorr_alg_rgdic, ncorr_alg_dispgrad, etc.) call MATLAB's
    % waitbar() via mexCallMATLAB.  Injecting a minimal stub at the front of the
    % path ensures those calls create invisible figures that are never shown.
    wb_stub_dir = tempname();
    mkdir(wb_stub_dir);
    % Use char(39) for single-quote to avoid MATLAB nested-quote confusion.
    % The fprintf calls below write a valid waitbar.m stub to wb_stub_dir.
    q = char(39);
    wb_lines = { ...
        'function h = waitbar(varargin)', ...
        '  % Stub: suppress ncorr MEX waitbar popups without showing figures', ...
        '  if nargin >= 2 && ~ischar(varargin{2}) && ~isstring(varargin{2}) && isscalar(varargin{2}) && isgraphics(varargin{2})', ...
        '    h = varargin{2};', ...
        '  else', ...
        sprintf('    h = figure(%sVisible%s,%soff%s,%sHandleVisibility%s,%scallback%s,%sIntegerHandle%s,%soff%s);', q,q,q,q,q,q,q,q,q,q,q,q), ...
        sprintf('    setappdata(h,%scanceling%s,0);', q, q), ...
        '  end', ...
        'end', ...
    };
    fid_wb = fopen(fullfile(wb_stub_dir,'waitbar.m'),'w');
    for wb_i = 1:numel(wb_lines)
        fprintf(fid_wb,'%s\n', wb_lines{wb_i});
    end
    fclose(fid_wb);
    addpath(wb_stub_dir, '-begin');
    rehash;
    wb_cleanup = onCleanup(@() batch_remove_waitbar_stub(wb_stub_dir));

    % Main loop
    for loop_i = 1:numel(idx_run)
        sample_i   = idx_run(loop_i);
        sample_dir = sample_dirs{sample_i};
        [~, sample_name] = fileparts(sample_dir);
        t_start = tic;

        fprintf('[%d/%d] %s ... ', sample_i, total_samples, sample_name);

        batch_results(loop_i).sample_name = sample_name;
        batch_results(loop_i).sample_dir  = sample_dir;
        batch_results(loop_i).output_path = '';
        batch_results(loop_i).status      = 'failed';
        batch_results(loop_i).message     = '';

        try
            % 1. Load TIFF frames
            tiff_files   = dir(fullfile(sample_dir, '*.tif*'));
            names_sorted = sort_natural({tiff_files.name});
            if numel(names_sorted) < 2
                error('Need >=2 images, found %d.', numel(names_sorted));
            end

            imgs_raw = cell(numel(names_sorted), 1);
            for k = 1:numel(names_sorted)
                imgs_raw{k} = load_tiff_gray(fullfile(sample_dir, names_sorted{k}));
            end

            timestamps = load_timestamps(sample_dir, names_sorted, options.verbose);

            % 2. Auto-ROI on the reference frame
            roi_mask = ncorr_auto_roi(imgs_raw{1}, options.roi_params);
            if isempty(roi_mask)
                error('ncorr_auto_roi returned empty mask.');
            end

            if options.save_roi_fig
                save_roi_figure(imgs_raw{1}, roi_mask, sample_name, output_dir);
            end

            % 3. Build ncorr imgs struct array (struct('imginfo',ncorr_class_img,'roi',ncorr_class_roi))
            %    ncorr_alg_dicanalysis expects this exact format.
            imgs_ncorr = build_ncorr_imgs(imgs_raw, roi_mask);

            % 4. Compute new ROI centroid (0-based)
            [rows_on, cols_on] = find(roi_mask);
            cx_new = (min(cols_on) + max(cols_on)) / 2 - 1;
            cy_new = (min(rows_on) + max(rows_on)) / 2 - 1;

            % 5. Transform seed positions to new ROI
            [seedinfo_new, seed_ok, seed_msg] = ncorr_seed_transform( ...
                cfg.seedinfo, ...
                cfg.roi_centroid(1), cfg.roi_centroid(2), ...
                cx_new, cy_new, ...
                cfg.dic_params.spacing, ...
                roi_mask);

            if ~seed_ok
                error('Seed transform failed: %s', seed_msg);
            end
            if options.verbose
                fprintf('\n  Seeds: %s', seed_msg);
            end

            % 7. DIC analysis (params_init populated - no GUI)
            if options.dry_run
                fprintf('(dry run - skipping DIC)\n');
                batch_results(loop_i).status    = 'skipped';
                batch_results(loop_i).message   = 'dry_run=true';
                batch_results(loop_i).elapsed_s = toc(t_start);
                continue;
            end

            [displacements_raw, rois_dic, ~, outstate_dic] = ncorr_alg_dicanalysis( ...
                imgs_ncorr, ...
                cfg.dic_params.radius, ...
                cfg.dic_params.spacing, ...
                cfg.dic_params.cutoff_diffnorm, ...
                cfg.dic_params.cutoff_iteration, ...
                cfg.dic_params.total_threads, ...
                cfg.dic_params.stepanalysis.enabled, ...
                cfg.dic_params.subsettrunc, ...
                0, ...
                numel(imgs_ncorr) - 1, ...
                [0 0 1 1], ...
                seedinfo_new);

            if outstate_dic ~= out.success
                error('ncorr_alg_dicanalysis returned non-success state (%d).', outstate_dic);
            end

            % 8. Format displacements
            pixtounits      = cfg.dic_params.pixtounits;
            units_str       = cfg.dic_params.units;
            cutoff_corrcoef = cfg.dic_params.cutoff_corrcoef;
            lenscoef        = cfg.dic_params.lenscoef;

            if isempty(pixtounits),      pixtounits = 1;        end
            if isempty(units_str),       units_str  = 'pixels'; end %#ok<NASGU>
            if isempty(cutoff_corrcoef), cutoff_corrcoef = 1.0; end
            if isempty(lenscoef),        lenscoef = 0;          end

            displacements_fmt = format_displacements(displacements_raw, rois_dic, ...
                                                     imgs_ncorr, cfg, ...
                                                     pixtounits, cutoff_corrcoef, lenscoef);

            % 9. Strain analysis (if strain_radius is set)
            strains    = struct();
            straininfo = struct('radius',[],'subsettrunc',[]);
            if ~isempty(cfg.strain_radius)
                [strains, straininfo, outstate_strain] = run_strain_analysis( ...
                    displacements_fmt, rois_dic, cfg, cfg.strain_radius);
                if outstate_strain ~= out.success
                    warning('ncorr_batch_run: strain analysis failed for %s', sample_name);
                    strains = struct();
                end
            end

            % 10. Package and save results
            results = struct();
            results.displacements = displacements_fmt;
            results.strains       = strains;
            results.dispinfo      = cfg.dic_params;
            results.straininfo    = straininfo;
            results.timestamps    = timestamps;
            results.metadata      = struct( ...
                'sample_name',       sample_name, ...
                'sample_dir',        sample_dir, ...
                'processed_at',      datestr(now,'yyyy-mm-dd HH:MM:SS'), ...
                'roi_mask',          roi_mask, ...
                'roi_centroid',      [cx_new, cy_new], ...
                'batch_config_path', batch_config_path, ...
                'num_frames',        numel(names_sorted));

            out_path = char(fullfile(char(output_dir), [char(sample_name) '_results.mat']));
            if ~ischar(out_path) || ~isrow(out_path)
                error('ncorr_batch_run: bad out_path (class=%s, size=%s)', class(out_path), mat2str(size(out_path)));
            end
            try
                save(out_path, 'results', '-v7.3');
            catch ME_save
                fprintf('  save failed for "%s" (class=%s, size=%s): %s\n', out_path, class(out_path), mat2str(size(out_path)), ME_save.message);
                rethrow(ME_save);
            end

            elapsed = toc(t_start);
            fprintf('done (%.1f s)\n', elapsed);
            batch_results(loop_i).output_path = out_path;
            batch_results(loop_i).status      = 'success';
            batch_results(loop_i).message     = 'OK';
            batch_results(loop_i).elapsed_s   = elapsed;

        catch ME
            elapsed = toc(t_start);
            msg = ME.message;
            fprintf('FAILED [%s]: %s\n', ME.identifier, msg);
            fprintf('  Stack:\n%s\n', getReport(ME,'extended'));
            fprintf(fid_log, '[%s] %s: %s\n', datestr(now,'yyyy-mm-dd HH:MM:SS'), sample_name, msg);
            batch_results(loop_i).status    = 'failed';
            batch_results(loop_i).message   = msg;
            batch_results(loop_i).elapsed_s = elapsed;
        end
    end

    fclose(fid_log);

    n_ok   = sum(strcmp({batch_results.status},'success'));
    n_fail = sum(strcmp({batch_results.status},'failed'));
    n_skip = sum(strcmp({batch_results.status},'skipped'));
    total_time = sum([batch_results.elapsed_s]);
    fprintf('\n=== Batch complete: %d success, %d failed, %d skipped | %.0f s total ===\n', ...
            n_ok, n_fail, n_skip, total_time);
    if n_fail > 0
        fprintf('  Failed samples logged to: %s\n', failed_log_path);
    end

    summary_path = fullfile(output_dir, 'batch_summary.mat');
    save(summary_path, 'batch_results', '-v7.3');
    fprintf('  Summary saved to: %s\n\n', summary_path);
end


% ======================================================================
% Local helpers
% ======================================================================

function names_sorted = sort_natural(names)
    tokens = regexp(names, '(\d+)', 'tokens');
    nums   = cellfun(@(t) str2double(t{end}{1}), tokens);
    [~, idx] = sort(nums);
    names_sorted = names(idx);
end


function img = load_tiff_gray(filepath)
    raw = imread(filepath);
    if ndims(raw) == 3, raw = rgb2gray(raw); end %#ok<ISMAT>
    switch class(raw)
        case 'uint8',  img = double(raw) / 255;
        case 'uint16', img = double(raw) / 65535;
        otherwise
            img = double(raw);
            mn = min(img(:)); mx = max(img(:));
            if mx > mn, img = (img-mn)/(mx-mn); end
    end
end


function timestamps = load_timestamps(sample_dir, names_sorted, verbose)
% Load frame timestamps from optional timestamps.csv; fall back to frame index.
    n = numel(names_sorted);
    csv_path = fullfile(sample_dir, 'timestamps.csv');
    if exist(csv_path,'file')
        try
            T = readmatrix(csv_path);
            % timestamps.csv has columns frame_index,time_s -> use time_s (last column)
            if size(T,2) >= 2, T = T(:,end); end
            T = T(:);
            if numel(T) >= n
                timestamps = T(1:n);
                if verbose
                    fprintf('\n  Loaded %d timestamps from timestamps.csv.', n);
                end
                return;
            end
        catch
        end
    end
    timestamps = (0:n-1)';
    if verbose
        fprintf('\n  No timestamps.csv; using frame indices as timestamps.');
    end
end


function imgs_ncorr = build_ncorr_imgs(imgs_raw, roi_mask)
% Build the struct array that ncorr_alg_dicanalysis expects:
%   struct('imginfo', <ncorr_class_img>, 'roi', <ncorr_class_roi>)
% set_img and set_roi are void methods on handle classes; never assign their return value.
    n = numel(imgs_raw);

    % Build one shared ROI object (same mask for all frames)
    roi_obj = ncorr_class_roi;
    roi_obj.set_roi('load', struct('mask', roi_mask, 'cutoff', 2000));

    imgs_ncorr = struct('imginfo', cell(1,n), 'roi', cell(1,n));
    for k = 1:n
        img_obj = ncorr_class_img;
        img_obj.set_img('load', struct('img',  imgs_raw{k}, ...
                                       'name', sprintf('frame_%04d', k), ...
                                       'path', ''));
        imgs_ncorr(k).imginfo = img_obj;
        imgs_ncorr(k).roi     = roi_obj;
    end
end


function displacements_fmt = format_displacements(displacements_raw, rois_dic, imgs_ncorr, cfg, pixtounits, cutoff_corrcoef, lenscoef)
% ncorr_alg_dicanalysis returns plot_u / plot_v / plot_corrcoef (no _dic suffix).
    n = numel(displacements_raw);
    displacements_fmt(n) = displacements_raw(n);
    for k = 1:n
        displacements_fmt(k) = displacements_raw(k);
        if pixtounits ~= 1
            displacements_fmt(k).plot_u = displacements_raw(k).plot_u * pixtounits;
            displacements_fmt(k).plot_v = displacements_raw(k).plot_v * pixtounits;
        end
        mask_cc = displacements_raw(k).plot_corrcoef > cutoff_corrcoef;
        displacements_fmt(k).plot_u(mask_cc) = NaN;
        displacements_fmt(k).plot_v(mask_cc) = NaN;
    end
    if lenscoef ~= 0 && exist('ncorr_alg_extrapdata','file')
        try
            [displacements_fmt, ~] = ncorr_alg_extrapdata(displacements_fmt, rois_dic, ...
                imgs_ncorr, cfg.dic_params.spacing, cfg.dic_params.radius, lenscoef);
        catch ME_lens
            warning('ncorr_batch_run: lens correction skipped (%s)', ME_lens.message);
        end
    end
end


function [strains, straininfo, outstate] = run_strain_analysis(displacements_fmt, rois_dic, cfg, strain_radius)
% Compute Green-Lagrangian strains using ncorr_alg_dispgrad.
%
% ncorr_alg_dispgrad inputs  (9):
%   plot_u, plot_v        – displacement maps at spacing-subsampled resolution
%   roi (formatted)       – ROI at spacing-subsampled resolution (rois_dic(k).formatted())
%   radius_strain (int32) – strain radius
%   pixtounits            – pixel-to-unit scale (1.0 for pixels)
%   spacing (int32)       – DIC spacing used during analysis
%   subsettrunc (logical) – subset truncation flag
%   num_img (int32)       – 0-based current image index
%   total_imgs (int32)    – total number of displacement images
%
% ncorr_alg_dispgrad outputs (2):
%   dg      – struct with plot_dudx, plot_dudy, plot_dvdx, plot_dvdy, plot_validpoints
%   outstate
%
% Green-Lagrangian strain (from ncorr.m lines 1668-1676):
%   exx = (1/2)*(2*dudx + dudx.^2 + dvdx.^2)
%   exy = (1/2)*(dudy + dvdx + dudx.*dudy + dvdx.*dvdy)
%   eyy = (1/2)*(2*dvdy + dudy.^2 + dvdy.^2)

    outstate   = out.failed;
    strains    = struct();
    straininfo = struct('radius', strain_radius, 'subsettrunc', cfg.dic_params.subsettrunc);
    n = numel(displacements_fmt);

    pixtounits  = cfg.dic_params.pixtounits;
    spacing     = cfg.dic_params.spacing;
    subsettrunc = cfg.dic_params.subsettrunc;
    if isempty(pixtounits), pixtounits = 1; end

    try
        for k = 1:n
            [dg, out_k] = ncorr_alg_dispgrad( ...
                displacements_fmt(k).plot_u, ...
                displacements_fmt(k).plot_v, ...
                rois_dic(k).formatted(), ...
                int32(strain_radius), ...
                double(pixtounits), ...
                int32(spacing), ...
                logical(subsettrunc), ...
                int32(k - 1), ...
                int32(n));
            if out_k ~= out.success
                warning('ncorr_batch_run: ncorr_alg_dispgrad failed for frame %d', k);
                return;
            end

            dudx = dg.plot_dudx;
            dudy = dg.plot_dudy;
            dvdx = dg.plot_dvdx;
            dvdy = dg.plot_dvdy;

            % Green-Lagrangian strain tensor components
            exx = (1/2) .* (2.*dudx + dudx.^2 + dvdx.^2);
            exy = (1/2) .* (dudy + dvdx + dudx.*dudy + dvdx.*dvdy);
            eyy = (1/2) .* (2.*dvdy + dudy.^2 + dvdy.^2);

            strains(k).plot_exx_ref_formatted = exx;
            strains(k).plot_exy_ref_formatted = exy;
            strains(k).plot_eyy_ref_formatted = eyy;
            strains(k).plot_validpoints       = dg.plot_validpoints;
        end
        outstate = out.success;
    catch ME_strain
        warning('ncorr_batch_run: strain analysis error: %s', ME_strain.message);
    end
end


function save_roi_figure(ref_img, roi_mask, sample_name, output_dir)
    fig = figure('Visible','off');
    imshow(ref_img); hold on;
    boundary = bwperim(roi_mask);
    [r,c] = find(boundary);
    scatter(c, r, 1, 'g', 'filled');
    title(sprintf('Auto ROI: %s', sample_name),'Interpreter','none');
    fig_path = fullfile(output_dir, [sample_name '_roi.png']);
    saveas(fig, fig_path);
    close(fig);
end

function batch_remove_waitbar_stub(d)
% Remove the injected waitbar stub directory from path and delete it.
    try; rmpath(d); catch; end
    try; delete(fullfile(d,'waitbar.m')); catch; end
    try; rmdir(d); catch; end
end
