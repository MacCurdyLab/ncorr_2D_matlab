function batch_config = ncorr_batch_setup(output_dir)
% NCORR_BATCH_SETUP  Interactive setup run - capture DIC config for batch automation.
%
% Runs the first (calibration) sample through the normal ncorr GUI so the
% user can set the ROI, DIC parameters, and seed positions interactively.
% After the user completes the full ncorr workflow, this function extracts
% all configuration needed for headless batch processing and saves it to
% batch_config.mat in output_dir.
%
% Usage
%   batch_config = ncorr_batch_setup();
%   batch_config = ncorr_batch_setup('/path/to/output');
%
% Workflow
%   1. User selects the calibration sample TIFF image stack folder.
%   2. Images are loaded and handed to the ncorr GUI.
%   3. User performs complete ncorr workflow:
%        Set Reference -> Set Current -> Set ROI -> Set DIC Params ->
%        Run DIC Analysis -> Format Displacements -> (optional) Strain Analysis
%   4. After ncorr figure is closed, the function extracts:
%        - DIC parameters  (data_dic.dispinfo)
%        - Seedinfo         (data_dic.seedinfo - stored by patched ncorr.m)
%        - ROI centroid     (computed from reference.roi.mask)
%        - Strain radius    (data_dic.straininfo.radius, if computed)
%   5. Configuration saved to batch_config.mat.
%
% Output struct  batch_config
%   .dic_params      struct; copy of data_dic.dispinfo
%   .seedinfo        struct array; captured seed paramvectors
%   .roi_centroid    [cx cy]; centroid of reference ROI (0-based, pixels)
%   .roi_mask        logical; reference ROI mask
%   .strain_radius   integer or []; strain radius if strain was computed
%   .setup_sample    char; path of calibration image stack folder
%   .created_at      char; timestamp
%   .output_dir      char; where batch_config.mat was saved
%
% See also ncorr_batch_run, ncorr_auto_roi, ncorr_seed_transform

    if nargin < 1 || isempty(output_dir)
        output_dir = uigetdir(pwd, 'Select output directory for batch_config.mat');
        if output_dir == 0
            error('ncorr_batch_setup: No output directory selected. Aborting.');
        end
    end
    if ~exist(output_dir,'dir')
        mkdir(output_dir);
    end

    fprintf('\n=== ncorr_batch_setup: Select calibration sample ===\n');
    sample_dir = uigetdir(pwd, 'Select calibration sample TIFF image stack folder');
    if sample_dir == 0
        error('ncorr_batch_setup: No sample folder selected. Aborting.');
    end

    fprintf('Loading images from: %s\n', sample_dir);
    tiff_files = dir(fullfile(sample_dir, '*.tif*'));
    tiff_files = sort_natural({tiff_files.name});

    if numel(tiff_files) < 2
        error('ncorr_batch_setup: Need at least 2 images. Found %d.', numel(tiff_files));
    end
    fprintf('Found %d TIFF frames.\n', numel(tiff_files));

    fprintf('\nLaunching ncorr GUI. Please complete the full workflow:\n');
    fprintf('  1. Reference and current images are pre-loaded.\n');
    fprintf('  2. Set ROI, set DIC parameters, run DIC analysis.\n');
    fprintf('  3. (Recommended) run Format Displacements and Strain Analysis.\n');
    fprintf('  4. Close the ncorr window when done.\n\n');

    handles_ncorr = ncorr();

    ref_path = fullfile(sample_dir, tiff_files{1});
    ref_raw  = load_tiff_gray(ref_path);
    handles_ncorr.set_ref(ref_raw);

    cur_imgs = cell(numel(tiff_files)-1, 1);
    for k = 2:numel(tiff_files)
        cur_imgs{k-1} = load_tiff_gray(fullfile(sample_dir, tiff_files{k}));
    end
    handles_ncorr.set_cur(cur_imgs);

    try
        waitfor(handles_ncorr.handles_gui.figure);
    catch
        % figure already destroyed (ncorr errored out) — continue to extraction
    end
    fprintf('\nncorr window closed. Extracting configuration...\n');

    % The ncorr handle object is INVALID after the figure closes.
    % Read from root appdata cache populated by patched ncorr.m during DIC.
    ncorr_cache = getappdata(0, 'ncorr_batch_pipeline_cache_');
    if isempty(ncorr_cache)
        error(['ncorr_batch_setup: no DIC results found in cache.\n' ...
               'Make sure DIC ran to completion using the patched ncorr.m.\n' ...
               'The cache is written by ncorr at the end of the DIC analysis step.']);
    end
    % Clean up so a stale cache does not persist across calls
    rmappdata(0, 'ncorr_batch_pipeline_cache_');

    if isempty(ncorr_cache.dispinfo) || isempty(ncorr_cache.dispinfo.radius)
        error('ncorr_batch_setup: DIC analysis was not completed. Aborting.');
    end
    if isempty(ncorr_cache.seedinfo)
        error(['ncorr_batch_setup: seedinfo was not captured. ' ...
               'Make sure you are using the patched ncorr.m.']);
    end

    batch_config = struct();
    batch_config.dic_params = ncorr_cache.dispinfo;
    batch_config.seedinfo   = ncorr_cache.seedinfo;
    batch_config.roi_mask   = logical(ncorr_cache.roi_mask);

    [rows_on, cols_on] = find(batch_config.roi_mask);
    batch_config.roi_centroid = [(min(cols_on)+max(cols_on))/2 - 1, ...
                                  (min(rows_on)+max(rows_on))/2 - 1];

    if ~isempty(ncorr_cache.straininfo) && ~isempty(ncorr_cache.straininfo.radius)
        batch_config.strain_radius = ncorr_cache.straininfo.radius;
    else
        batch_config.strain_radius = [];
        fprintf('  Note: strain_radius not captured (strain analysis not run).\n');
    end

    batch_config.setup_sample = sample_dir;
    batch_config.created_at   = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    batch_config.output_dir   = output_dir;

    config_path = fullfile(output_dir, 'batch_config.mat');
    save(config_path, 'batch_config', '-v7.3');

    fprintf('\n=== Setup complete ===\n');
    fprintf('  DIC radius:    %d\n',   batch_config.dic_params.radius);
    fprintf('  DIC spacing:   %d\n',   batch_config.dic_params.spacing);
    fprintf('  Seeds saved:   %d threads x %d regions\n', ...
            size(batch_config.seedinfo,1), size(batch_config.seedinfo,2));
    fprintf('  ROI centroid:  [%.1f, %.1f] (0-based px)\n', ...
            batch_config.roi_centroid(1), batch_config.roi_centroid(2));
    fprintf('  Saved to: %s\n\n', config_path);
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
    if ndims(raw) == 3  %#ok<ISMAT>
        raw = rgb2gray(raw);
    end
    switch class(raw)
        case 'uint8',  img = double(raw) / 255;
        case 'uint16', img = double(raw) / 65535;
        otherwise
            img = double(raw);
            mn = min(img(:)); mx = max(img(:));
            if mx > mn, img = (img-mn)/(mx-mn); end
    end
end
