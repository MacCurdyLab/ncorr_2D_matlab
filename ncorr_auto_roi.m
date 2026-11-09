function roi_mask = ncorr_auto_roi(ref_img, params)
% NCORR_AUTO_ROI  Automatically segment specimen ROI from a DIC reference frame.
%
% Applies Gaussian blur + Otsu thresholding + morphological cleanup +
% boundary smoothing to isolate the specimen from the background.
% An optional interactive preview lets the user accept or redraw the mask.
%
% Inputs
%   ref_img  - 2D grayscale image (double, uint8, or uint16).
%              Colour images are silently converted to greyscale.
%   params   - (optional) struct with any of the following fields:
%
%     .blur_sigma      Gaussian blur sigma before thresholding (default 3).
%                      Increase if the speckle pattern confuses Otsu.
%     .close_radius    Morphological closing disk radius in pixels (default 15).
%                      Fills gaps within the speckle field.
%     .erode_radius    Morphological erosion disk radius in pixels (default 5).
%                      Safety margin that pulls the mask away from edges.
%     .smooth_sigma    Gaussian smoothing applied to the binary mask to round
%                      off jagged speckle-induced boundaries (default 12).
%                      Higher values give a smoother outline at the cost of
%                      slightly less faithfully following concave geometry.
%                      Set to 0 to disable boundary smoothing.
%     .show_preview    Show the proposed mask before returning (default true).
%     .fallback_to_gui If validation fails AND show_preview is true, open
%                      ncorr_gui_setrois for manual drawing (default true).
%     .min_area        Minimum acceptable ROI area in pixels (default 2000).
%
% Output
%   roi_mask - logical array the same size as ref_img.  true = inside ROI.
%              Returns empty ([]) on cancel or irrecoverable failure.
%
% Example
%   mask = ncorr_auto_roi(imread('ref_frame.tif'));
%   mask = ncorr_auto_roi(ref_img, struct('smooth_sigma',20,'show_preview',false));

    % ------------------------------------------------------------------
    % Default parameters
    % ------------------------------------------------------------------
    if nargin < 2 || isempty(params), params = struct(); end
    if ~isfield(params,'blur_sigma'),      params.blur_sigma      = 3;    end
    if ~isfield(params,'close_radius'),    params.close_radius    = 15;   end
    if ~isfield(params,'erode_radius'),    params.erode_radius    = 5;    end
    if ~isfield(params,'smooth_sigma'),    params.smooth_sigma    = 12;   end
    if ~isfield(params,'show_preview'),    params.show_preview    = true; end
    if ~isfield(params,'fallback_to_gui'), params.fallback_to_gui = true; end
    if ~isfield(params,'min_area'),        params.min_area        = 2000; end

    roi_mask = [];

    % ------------------------------------------------------------------
    % Normalise input to double [0,1]
    % ------------------------------------------------------------------
    if ndims(ref_img) == 3 %#ok<ISMAT>
        ref_img = rgb2gray(ref_img);
    end
    img_class = class(ref_img);
    if strcmp(img_class,'uint8')
        img_d = double(ref_img) / 255;
    elseif strcmp(img_class,'uint16')
        img_d = double(ref_img) / 65535;
    else
        img_d = double(ref_img);
        mn = min(img_d(:)); mx = max(img_d(:));
        if mx > mn, img_d = (img_d - mn) / (mx - mn); end
    end

    % ------------------------------------------------------------------
    % Step 1: Gaussian blur to suppress speckle before thresholding
    % ------------------------------------------------------------------
    img_blur = imgaussfilt(img_d, params.blur_sigma);

    % ------------------------------------------------------------------
    % Step 2: Otsu thresholding
    % ------------------------------------------------------------------
    thresh = graythresh(img_blur);
    bw = imbinarize(img_blur, thresh);

    % ------------------------------------------------------------------
    % Step 3: Morphological cleanup
    % ------------------------------------------------------------------
    se_close = strel('disk', params.close_radius);
    se_erode = strel('disk', params.erode_radius);

    bw = imclose(bw, se_close);
    bw = imfill(bw, 'holes');

    % Keep only the largest connected component
    cc = bwconncomp(bw);
    if cc.NumObjects == 0
        warning('ncorr_auto_roi: Otsu produced an empty mask. Trying inverted threshold.');
        bw = ~imbinarize(img_blur, thresh);
        bw = imclose(bw, se_close);
        bw = imfill(bw, 'holes');
        cc = bwconncomp(bw);
    end

    if cc.NumObjects > 0
        num_pixels = cellfun(@numel, cc.PixelIdxList);
        [~, largest_idx] = max(num_pixels);
        bw_largest = false(size(bw));
        bw_largest(cc.PixelIdxList{largest_idx}) = true;
        bw = bw_largest;
    end

    bw = imerode(bw, se_erode);

    % ------------------------------------------------------------------
    % Step 4: Boundary smoothing
    %   Blur the binary mask as a floating-point array and re-threshold
    %   at 0.5.  This rounds off jagged speckle-induced edges while
    %   preserving concave geometry (unlike convex hull).
    % ------------------------------------------------------------------
    if params.smooth_sigma > 0
        bw_smooth = imgaussfilt(double(bw), params.smooth_sigma) > 0.5;
        bw = bw_smooth;
    end

    % ------------------------------------------------------------------
    % Step 5: Validate minimum area
    % ------------------------------------------------------------------
    area = sum(bw(:));
    auto_valid = (area >= params.min_area);

    if ~auto_valid
        warning('ncorr_auto_roi: ROI has only %d pixels (minimum %d).', area, params.min_area);
    end

    % ------------------------------------------------------------------
    % Step 6: Optional interactive preview
    % ------------------------------------------------------------------
    if params.show_preview
        fig_prev = figure('Name','ncorr_auto_roi - ROI Preview', ...
                          'NumberTitle','off','Toolbar','none','Menubar','none');
        ax = axes('Parent',fig_prev);

        imshow(img_d,'Parent',ax); hold(ax,'on');
        boundary_overlay = bwperim(bw);
        green_layer = cat(3, zeros(size(bw)), ones(size(bw)), zeros(size(bw)));
        h_overlay = imshow(green_layer,'Parent',ax);
        set(h_overlay,'AlphaData',double(boundary_overlay) * 0.9);
        hold(ax,'off');
        title(ax, sprintf('Auto ROI  |  Area: %d px  |  Smooth sigma: %d', ...
                          area, params.smooth_sigma));

        btn_w = 100; btn_h = 30; gap = 10;
        uicontrol('Parent',fig_prev,'Style','pushbutton','String','Accept','FontSize',10, ...
            'Position',[gap, gap, btn_w, btn_h], ...
            'Callback',@(~,~) uiresume(fig_prev));
        if params.fallback_to_gui
            uicontrol('Parent',fig_prev,'Style','pushbutton','String','Draw Manually','FontSize',10, ...
                'Position',[gap*2+btn_w, gap, btn_w+20, btn_h], ...
                'Callback',@(~,~) setappdata(fig_prev,'user_choice','manual') & uiresume(fig_prev)); %#ok<NBRAK>
        end
        uicontrol('Parent',fig_prev,'Style','pushbutton','String','Cancel','FontSize',10, ...
            'Position',[gap*3+btn_w*2+20, gap, btn_w, btn_h], ...
            'Callback',@(~,~) setappdata(fig_prev,'user_choice','cancel') & uiresume(fig_prev)); %#ok<NBRAK>

        setappdata(fig_prev,'user_choice','accept');
        uiwait(fig_prev);

        if ~ishandle(fig_prev)
            roi_mask = [];
            return;
        end

        user_choice = getappdata(fig_prev,'user_choice');
        close(fig_prev);

        switch user_choice
            case 'accept'
                roi_mask = bw;
            case 'cancel'
                roi_mask = [];
                return;
            case 'manual'
                roi_mask = [];
        end
    else
        if auto_valid
            roi_mask = bw;
        else
            roi_mask = [];
        end
        return;
    end

    % ------------------------------------------------------------------
    % Step 7: Fallback to ncorr_gui_setrois if needed
    % ------------------------------------------------------------------
    if isempty(roi_mask) && params.fallback_to_gui
        fprintf('ncorr_auto_roi: opening ncorr_gui_setrois for manual ROI drawing.\n');
        ref_ncorr = ncorr_class_img;
        ref_ncorr = ref_ncorr.set_img(ref_img);
        [rois, outstate] = ncorr_gui_setrois(ref_ncorr, [0 0 1 1], ncorr_class_roi.empty);
        if outstate == out.success && ~isempty(rois)
            roi_mask = logical(rois(1).mask);
        else
            roi_mask = [];
        end
    end
end
