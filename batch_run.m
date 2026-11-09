%%

sample_dirs = {
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\DIC Test Data\20261105 DIC Data collection\Spec_3\spec_3-repeat_strain-image_stack",
};

%%

% sample_dirs = {"C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\DIC Test Data\20261105 DIC Data collection\Spec_1\spec_1-break0001-ref_stack"};

batch_config = ncorr_batch_setup("C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\DIC Test Data\20261105 DIC Data collection\Analysis");
%%
batch_results = ncorr_batch_run(...
"C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\DIC Test Data\20261105 DIC Data collection\Analysis\batch_config.mat", ...
sample_dirs, ...
"C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\DIC Test Data\20261105 DIC Data collection\Analysis\results" ...
);